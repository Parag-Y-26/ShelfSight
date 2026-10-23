import sqlite3
import struct
import time
from datetime import UTC, datetime

import cv2
import numpy as np
import pytest
from cryptography import x509
from fastapi import HTTPException

from shelfsight.__main__ import tls_material
from shelfsight.config import ROOT, BusinessConfig, Settings
from shelfsight.providers import (
    DisabledDecisionEngine,
    GeminiVisionModel,
    MediaPipeDetector,
    base64_image,
    decode_image,
)
from shelfsight.security import FirebaseVerifier


def test_firebase_claim_checks_are_explicit(monkeypatch):
    valid = {
        "sub": "owner",
        "iss": "https://securetoken.google.com/sample-project",
        "aud": "sample-project",
        "exp": time.time() + 100,
        "iat": time.time() - 1,
    }
    verifier = FirebaseVerifier("sample-project")
    monkeypatch.setattr("shelfsight.security.id_token.verify_firebase_token", lambda *a, **kw: valid)
    assert verifier.verify("signed-token") == "owner"
    for field, bad in (
        ("iss", "https://attacker"),
        ("aud", "other-project"),
        ("sub", ""),
        ("exp", 0),
        ("iat", time.time() + 10),
    ):
        original = valid[field]
        valid[field] = bad
        with pytest.raises(HTTPException) as failure:
            verifier.verify("signed-token")
        assert failure.value.status_code == 401
        valid[field] = original
    with pytest.raises(HTTPException) as failure:
        FirebaseVerifier("").verify("anything")
    assert failure.value.status_code == 503


def test_image_size_and_encoded_validation():
    config = BusinessConfig(ROOT / "config/defaults.json")
    # Header is enough to reject a decompression bomb before image decoding.
    bomb = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 50000, 50000)
    with pytest.raises(HTTPException) as failure:
        decode_image(bomb, config)
    assert failure.value.status_code == 413
    with pytest.raises(HTTPException):
        base64_image("%%%", config)
    _, encoded = cv2.imencode(".jpg", np.zeros((8, 12, 3), dtype=np.uint8))
    assert decode_image(encoded.tobytes(), config).shape == (8, 12, 3)


def test_providers_fail_closed_without_configuration(tmp_path):
    settings = Settings(
        runtime_dir=tmp_path, model_path=None, gemini_api_key="", gemini_model="", _env_file=None
    )
    config = BusinessConfig(ROOT / "config/defaults.json")
    assert MediaPipeDetector(settings).available is False
    assert GeminiVisionModel(settings, config).available is False
    assert DisabledDecisionEngine().decide("anything", "text", []) is None
    with pytest.raises(HTTPException) as failure:
        GeminiVisionModel(settings, config).scan(b"none")
    assert failure.value.status_code == 503


def test_tls_fingerprint_is_der_digest_and_certificate_is_reused(tmp_path):
    key, cert, fingerprint = tls_material(tmp_path, "192.0.2.42")
    assert key.exists() and cert.exists() and len(fingerprint) == 64
    assert tls_material(tmp_path, "192.0.2.42")[2] == fingerprint
    certificate = x509.load_pem_x509_certificate(cert.read_bytes())
    assert certificate.not_valid_after_utc > datetime.now(UTC)


def test_events_cannot_be_mutated(store):
    client, app, headers, data, detector = store
    event = app.state.db.event("a", data["store"]["id"], "test", {})
    with pytest.raises(sqlite3.IntegrityError):
        app.state.db.execute("UPDATE events SET kind='tampered' WHERE id=?", (event["id"],))
