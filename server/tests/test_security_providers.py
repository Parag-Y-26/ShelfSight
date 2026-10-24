import sqlite3
import struct
from datetime import UTC, datetime
from types import SimpleNamespace

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
from shelfsight.security import SupabaseVerifier


def test_supabase_verifier_asks_trusted_auth_service_for_user(monkeypatch):
    calls = []
    response = SimpleNamespace(
        status_code=200, json=lambda: {"id": "a6d5c56b-9c1e-4cf3-92fd-1234567890ab"}
    )

    def fake_get(url, *, headers, timeout):
        calls.append((url, headers, timeout))
        return response

    monkeypatch.setattr("shelfsight.security.httpx.get", fake_get)
    verifier = SupabaseVerifier("https://project.supabase.co/", "sb_publishable_test")
    assert verifier.verify("access-token") == "a6d5c56b-9c1e-4cf3-92fd-1234567890ab"
    assert calls == [
        (
            "https://project.supabase.co/auth/v1/user",
            {"apikey": "sb_publishable_test", "Authorization": "Bearer access-token"},
            5.0,
        )
    ]


def test_supabase_verifier_rejects_invalid_tokens_and_missing_config(monkeypatch):
    from shelfsight.security import SupabaseVerifier

    monkeypatch.setattr(
        "shelfsight.security.httpx.get",
        lambda *a, **kw: SimpleNamespace(status_code=401, json=lambda: {"message": "invalid"}),
    )
    with pytest.raises(HTTPException) as failure:
        SupabaseVerifier("https://project.supabase.co", "sb_publishable_test").verify("bad")
    assert failure.value.status_code == 401
    with pytest.raises(HTTPException) as failure:
        SupabaseVerifier("", "").verify("anything")
    assert failure.value.status_code == 503


def test_supabase_verifier_fails_closed_on_auth_service_unavailability(monkeypatch):
    import httpx

    def fail(*args, **kwargs):
        raise httpx.ConnectError("offline")

    monkeypatch.setattr("shelfsight.security.httpx.get", fail)
    with pytest.raises(HTTPException) as failure:
        SupabaseVerifier("https://project.supabase.co", "sb_publishable_test").verify("token")
    assert failure.value.status_code == 503


def test_image_size_and_encoded_validation():
    config = BusinessConfig(ROOT / "app/assets/defaults.json")
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
    config = BusinessConfig(ROOT / "app/assets/defaults.json")
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
