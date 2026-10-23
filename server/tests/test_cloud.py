"""Cloud entry points must keep Firebase authentication and owner isolation."""

from conftest import TestDetector, TestVerifier, TestVision
from fastapi.testclient import TestClient

from shelfsight.api import create_app
from shelfsight.config import ROOT, Settings


def test_cloud_login_is_disabled_locally(environment):
    client, _, _, _ = environment
    assert client.post("/v1/cloud-session", json={"device_name": "Browser"}).status_code == 404


def test_cloud_login_and_static_boundaries(tmp_path):
    web = tmp_path / "web"
    web.mkdir()
    (web / "index.html").write_text("<title>ShelfSight</title>")
    app = create_app(
        Settings(
            cloud_mode=True,
            web_dir=web,
            runtime_dir=tmp_path,
            config_path=ROOT / "config/defaults.json",
            _env_file=None,
        ),
        verifier=TestVerifier(),
        detector=TestDetector(),
        vision=TestVision(),
    )
    with TestClient(app) as client:
        assert client.post("/v1/cloud-session", json={"device_name": "Browser"}).status_code == 401
        assert (
            client.post(
                "/v1/cloud-session",
                json={"device_name": "Browser"},
                headers={"Authorization": "Bearer invalid"},
            ).status_code
            == 401
        )
        response = client.post(
            "/v1/cloud-session",
            json={"device_name": "Browser"},
            headers={"Authorization": "Bearer identity-a"},
        )
        assert response.status_code == 200
        token = response.json()["session_token"]
        stores = client.get("/v1/stores", headers={"Authorization": f"Bearer {token}"})
        assert stores.json() == {"items": []}
        assert "ShelfSight" in client.get("/").text
        assert client.get("/.env").status_code == 404
        assert client.get("/v1/missing").status_code == 404
    app.state.db.close()
