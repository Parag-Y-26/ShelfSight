"""Fixtures inject test-only identity/model providers; production has no fake path."""

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from shelfsight.api import create_app
from shelfsight.config import ROOT, Settings
from shelfsight.db import Database
from shelfsight.providers import Detection


class TestVerifier:
    def verify(self, token):
        if token in {"identity-a", "identity-b"}:
            return token[-1]
        raise HTTPException(401, "Test identity rejected")


class TestDetector:
    available, reason = True, "Test-only detector"
    detections = [Detection((0.1, 0.1, 0.2, 0.4), 0.9)]

    def detect(self, image, confidence):
        return self.detections


class TestVision:
    available, reason = False, "Test scan unavailable"

    def scan(self, image):
        raise HTTPException(503, self.reason)


@pytest.fixture
def environment(tmp_path):
    db = Database(tmp_path / "test.sqlite3")
    settings = Settings(
        runtime_dir=tmp_path,
        config_path=ROOT / "app" / "assets" / "defaults.json",
        supabase_url="https://test.supabase.co",
        supabase_publishable_key="sb_publishable_test",
        _env_file=None,
    )
    detector = TestDetector()
    app = create_app(settings, db=db, verifier=TestVerifier(), detector=detector, vision=TestVision())
    with TestClient(app) as client:

        def pair(who="a"):
            secret, _ = app.state.sessions.issue_pairing()
            response = client.post(
                "/v1/pair",
                headers={"Authorization": f"Bearer identity-{who}"},
                json={"pairing_secret": secret, "device_name": "Test device"},
            )
            assert response.status_code == 200, response.text
            return {"Authorization": "Bearer " + response.json()["session_token"]}

        yield client, app, pair, detector
    db.close()


@pytest.fixture
def store(environment):
    client, app, pair, detector = environment
    headers = pair()
    response = client.post(
        "/v1/stores",
        headers=headers,
        json={
            "name": "Willow Supplies",
            "type_id": "general",
            "goal_id": "demand",
            "currency": "USD",
            "unit": "m",
            "timezone": "UTC",
            "shelf_count": 2,
            "floor": {"name": "North room", "width": 12, "length": 9},
        },
    )
    assert response.status_code == 201, response.text
    data = client.get(f"/v1/stores/{response.json()['id']}/snapshot", headers=headers).json()
    return client, app, headers, data, detector
