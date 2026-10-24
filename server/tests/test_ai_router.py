import json

import pytest

from shelfsight.config import BusinessConfig, Settings
from shelfsight.vision_compatible import AiProviderRouter, AiRoutingError


def config():
    return BusinessConfig(Settings(_env_file=None).config_path)


def test_native_gemini_schema_and_fallback_payloads():
    calls = []

    def post(url, headers, payload, timeout):
        calls.append((url, headers, payload))
        if len(calls) < 3:
            raise TimeoutError("credential must never leak")
        return {
            "model": "google/gemini-2.5-flash",
            "choices": [{"message": {"content": '{"candidates":[]}'}, "finish_reason": "stop"}],
        }

    router = AiProviderRouter(
        config(),
        credentials=dict.fromkeys(["gemini", "nvidia_nim", "openrouter"], "test-secret"),
        post=post,
    )
    result = router.generate("shelf_scan", "Identify products", image=b"\xff\xd8image")
    assert result["provider"] == "openrouter"
    assert len(calls) == 3
    assert calls[0][1]["x-goog-api-key"] == "test-secret"
    assert "test-secret" not in calls[0][0]
    gemini = calls[0][2]
    assert gemini["generationConfig"]["responseMimeType"] == "application/json"
    assert gemini["generationConfig"]["responseSchema"]["type"] == "OBJECT"
    assert gemini["contents"][0]["parts"][1]["inlineData"]["mimeType"] == "image/jpeg"
    nim = calls[1][2]
    assert nim["response_format"]["type"] == "json_schema"
    assert nim["messages"][1]["content"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert calls[2][1]["X-Title"] == "ShelfSight"
    assert calls[2][1]["HTTP-Referer"] == "https://shelfsight.app"
    assert calls[2][2]["models"][1:] == config().data["ai"]["providers"]["openrouter"]["fallback_models"]


def test_schema_failure_fails_over_and_errors_do_not_expose_keys():
    def post(url, headers, payload, timeout):
        return {"choices": [{"message": {"content": json.dumps({"candidates": "invented"})}}]}

    router = AiProviderRouter(config(), credentials={"openrouter": "secret-value"}, post=post)
    with pytest.raises(AiRoutingError) as error:
        router.generate("shelf_scan", "test")
    assert "secret-value" not in str(error.value)
    assert router.health()["openrouter"]["error_rate"] == 1


def test_connection_test_never_silently_tests_another_key():
    calls = []

    def post(*args):
        calls.append(args)
        raise TimeoutError()

    router = AiProviderRouter(config(), credentials={"gemini": "a", "openrouter": "b"}, post=post)
    with pytest.raises(AiRoutingError):
        router.test_connection("gemini")
    assert len(calls) == 1


def test_key_only_native_server_scan_uses_router_and_exposes_no_secrets(tmp_path):
    import cv2
    import numpy as np
    from conftest import TestDetector, TestVerifier
    from fastapi.testclient import TestClient

    from shelfsight.api import create_app
    from shelfsight.db import Database

    db = Database(":memory:")
    settings = Settings(
        _env_file=None,
        runtime_dir=tmp_path,
        gemini_api_key="private-server-key",
        gemini_model="",
        vision_provider="gemini",
        nvidia_nim_api_key="",
        openrouter_api_key="",
        laya_endpoint_url="",
    )
    app = create_app(settings, db=db, verifier=TestVerifier(), detector=TestDetector())
    app.state.ai_router.post = lambda *args: {
        "candidates": [
            {"finishReason": "STOP", "content": {"parts": [{"text": '```json\n{"candidates":[]}\n```'}]}}
        ]
    }
    store = db.create("store", "a", "", {"settings": {}})
    with TestClient(app) as client:
        secret, _ = app.state.sessions.issue_pairing()
        session = client.post(
            "/v1/pair",
            headers={"Authorization": "Bearer identity-a"},
            json={"pairing_secret": secret, "device_name": "Unit test"},
        ).json()
        headers = {"Authorization": "Bearer " + session["session_token"]}
        _, image = cv2.imencode(".png", np.zeros((5, 5, 3), dtype=np.uint8))
        response = client.post(
            f"/v1/stores/{store['id']}/scan",
            headers=headers,
            files={"file": ("test.png", image.tobytes(), "image/png")},
        )
        assert response.status_code == 200, response.text
        assert response.json()["source"] == "gemini"
        assert response.json()["model"] == "gemini-2.5-flash"
        public = client.get("/v1/config", headers=headers)
        assert public.json()["capabilities"]["shelf_scan"] is True
        assert public.json()["providers"]["decision_engine"]["available"] is True
        assert "private-server-key" not in public.text
    db.close()
