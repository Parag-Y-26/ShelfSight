"""Cloud entry points must keep Supabase authentication and owner isolation."""

import pytest
from conftest import TestDetector, TestVerifier, TestVision
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from shelfsight.api import create_app
from shelfsight.config import ROOT, BusinessConfig, Settings


@pytest.fixture
def cloud_environment(tmp_path):
    app = create_app(
        Settings(
            cloud_mode=True,
            runtime_dir=tmp_path,
            config_path=ROOT / "app/assets/defaults.json",
            _env_file=None,
        ),
        verifier=TestVerifier(),
        detector=TestDetector(),
        vision=TestVision(),
    )
    with TestClient(app) as client:

        def login(who="a"):
            response = client.post(
                "/v1/cloud-session",
                json={"device_name": "Browser"},
                headers={"Authorization": f"Bearer identity-{who}"},
            )
            assert response.status_code == 200, response.text
            return {"Authorization": "Bearer " + response.json()["session_token"]}

        yield client, app, login
    app.state.db.close()


def start_monitoring(client, headers):
    response = client.post(
        "/v1/stores",
        headers=headers,
        json={
            "name": "Cloud store",
            "type_id": "general",
            "goal_id": "demand",
            "currency": "USD",
            "unit": "m",
            "timezone": "UTC",
            "shelf_count": 1,
            "floor": {"name": "Floor", "width": 12, "length": 9},
        },
    )
    assert response.status_code == 201, response.text
    store_id = response.json()["id"]
    data = client.get(f"/v1/stores/{store_id}/snapshot", headers=headers).json()
    calibration = client.post(
        f"/v1/stores/{store_id}/calibrations",
        headers=headers,
        json={
            "orientation": "portraitUp",
            "frame_width": 100,
            "frame_height": 100,
            "zones": [{"shelf_id": data["shelves"][0]["id"], "x": 0, "y": 0, "width": 1, "height": 1}],
        },
    )
    assert calibration.status_code == 201, calibration.text
    response = client.post(
        f"/v1/stores/{store_id}/monitoring",
        headers=headers,
        json={"calibration_id": calibration.json()["id"]},
    )
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_cloud_login_is_disabled_locally(environment):
    client, _, _, _ = environment
    assert client.post("/v1/cloud-session", json={"device_name": "Browser"}).status_code == 404


def test_cloud_configuration_is_truthful_and_does_not_mutate_defaults(cloud_environment):
    client, app, login = cloud_environment
    defaults = BusinessConfig(ROOT / "app/assets/defaults.json").public()
    headers = login()
    response = client.get("/v1/config", headers=headers)
    assert response.status_code == 200
    data = response.json()
    assert data["deployment"] == {"mode": "cloud", "persistence": "ephemeral_demo"}
    strings = data["strings"]["en"]
    assert "encrypted HTTPS" in strings["privacySummary"]
    assert "discarded" in strings["privacySummary"]
    assert "Anonymous tracking IDs last only" in strings["privacySummary"]
    assert "encrypted connection" in strings["monitorPrivacy"]
    for key in (
        "provider_detector",
        "monitorStarting",
        "connectionFailed",
        "sessionExpired",
        "invalidResponse",
    ):
        assert "cloud" in strings[key].lower()
    assert app.state.config.public() == defaults
    assert client.get("/v1/config", headers=headers).json() == data


def test_local_configuration_preserves_business_defaults(environment):
    client, app, pair, _ = environment
    data = client.get("/v1/config", headers=pair()).json()
    assert data["strings"] == app.state.config.data["strings"]
    assert "deployment" not in data


def test_browser_stream_ticket_is_single_use(cloud_environment):
    client, _, login = cloud_environment
    headers = login()
    session_id = start_monitoring(client, headers)
    path = f"/v1/monitoring/{session_id}/stream"
    response = client.post(f"{path}/ticket", headers=headers)
    assert response.status_code == 200
    proof = response.json()
    assert proof["expires_in"] == 30
    protocols = ["shelfsight", proof["ticket"]]
    with client.websocket_connect(path, subprotocols=protocols) as stream:
        assert stream.accepted_subprotocol == "shelfsight"
        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect(path, subprotocols=protocols):
                pytest.fail("A consumed browser stream ticket was accepted")
        assert rejected.value.code == 1008


@pytest.mark.parametrize("other_owner", [False, True])
def test_browser_stream_ticket_rejects_wrong_session_and_owner(cloud_environment, other_owner):
    client, _, login = cloud_environment
    headers = login()
    other_headers = login("b") if other_owner else headers
    session_id = start_monitoring(client, headers)
    other_session = start_monitoring(client, other_headers)
    path = f"/v1/monitoring/{session_id}/stream"
    if other_owner:
        assert client.post(f"{path}/ticket", headers=other_headers).status_code == 404
    response = client.post(f"{path}/ticket", headers=headers)
    assert response.status_code == 200
    protocols = ["shelfsight", response.json()["ticket"]]
    with pytest.raises(WebSocketDisconnect) as rejected:
        with client.websocket_connect(
            f"/v1/monitoring/{other_session}/stream", subprotocols=protocols
        ):
            pytest.fail("A ticket for another monitoring session was accepted")
    assert rejected.value.code == 1008
    # A rejected attempt also consumes the ticket, so it cannot subsequently be replayed.
    with pytest.raises(WebSocketDisconnect) as rejected:
        with client.websocket_connect(path, subprotocols=protocols):
            pytest.fail("A previously rejected browser stream ticket was accepted")
    assert rejected.value.code == 1008


def test_cloud_login_and_static_boundaries(tmp_path):
    web = tmp_path / "web"
    web.mkdir()
    (web / "index.html").write_text("<title>ShelfSight</title>")
    app = create_app(
        Settings(
            cloud_mode=True,
            web_dir=web,
            runtime_dir=tmp_path,
            config_path=ROOT / "app/assets/defaults.json",
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
