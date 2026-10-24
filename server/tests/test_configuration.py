"""Configuration contracts shared by the server and the device settings editor."""

import pytest

from shelfsight.config import BusinessConfig, Settings


def test_single_canonical_defaults_and_required_values():
    config = BusinessConfig(Settings(_env_file=None).config_path)
    assert config.data["schema_version"] == 2
    assert config.data["settings"]["detection_confidence_threshold"] == 0.45
    assert config.data["settings"]["dwell_cutoff_sec"] == 3.0
    assert config.data["settings"]["monitoring_sample_fps"] == 5
    assert config.data["settings"]["tracking_grace_sec"] == 1.5
    assert config.data["settings"]["low_stock_threshold"] == 5
    assert config.data["settings"]["active_ai_provider"] == "auto"


def test_shelf_store_device_global_cascade_and_legacy_migration():
    config = BusinessConfig(Settings(_env_file=None).config_path)
    store = {"settings": {"dwell_seconds": 4, "low_stock": 7}}
    shelf = {"settings": {"dwell_cutoff_sec": 6}}
    assert config.thresholds()["dwell_cutoff_sec"] == 3
    assert config.thresholds(store)["dwell_cutoff_sec"] == 4
    assert config.thresholds(store, shelf)["dwell_cutoff_sec"] == 6
    assert config.thresholds(store, shelf, {"dwell_cutoff_sec": 8})["dwell_cutoff_sec"] == 6
    assert config.thresholds(None, None, {"dwell_cutoff_sec": 8})["dwell_cutoff_sec"] == 8
    assert config.validate_overrides({"monitoring_interval_ms": 200}) == {"monitoring_sample_fps": 5}
    assert config.validate_overrides({"low_stock": 9, "low_stock_threshold": 2}) == {
        "low_stock_threshold": 2
    }


@pytest.mark.parametrize(
    "overrides",
    [
        {"monitoring_sample_fps": 0},
        {"monitoring_sample_fps": 0.2},
        {"detection_confidence_threshold": 1.1},
        {"tracking_grace_sec": -1},
        {"low_stock_threshold": 2.5},
        {"dwell_cutoff_sec": True},
        {"active_ai_provider": "fake"},
        {"execution_mode": "pretend"},
        {"frame_max_dimension": 100_000},
        {"unknown": 1},
    ],
)
def test_invalid_runtime_settings_fail_closed(overrides):
    with pytest.raises(ValueError):
        BusinessConfig(Settings(_env_file=None).config_path).validate_overrides(overrides)


def test_runtime_provider_settings_are_accepted_and_persisted(store):
    client, app, headers, snapshot, _ = store
    store_id = snapshot["store"]["id"]
    response = client.patch(
        f"/v1/stores/{store_id}",
        headers=headers,
        json={
            "settings": {
                "active_ai_provider": "openrouter",
                "execution_mode": "remote_server",
                "dwell_cutoff_sec": 7,
            }
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["settings"]["active_ai_provider"] == "openrouter"
    assert app.state.config.thresholds(response.json())["dwell_cutoff_sec"] == 7


def test_fresh_owner_has_no_seeded_records(environment):
    client, app, pair, _ = environment
    assert client.get("/v1/stores", headers=pair()).json() == {"items": []}
    assert app.state.db.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 0


def test_current_analytics_includes_events_at_same_clock_tick(store, monkeypatch):
    from test_api import add_item

    monkeypatch.setattr("shelfsight.api.utc_now", lambda: "2026-10-24T06:00:00Z")
    monkeypatch.setattr("shelfsight.db.utc_now", lambda: "2026-10-24T06:00:00Z")
    client, _, headers, snapshot, _ = store
    _, item = add_item(client, headers, snapshot)
    client.patch(f"/v1/items/{item['id']}", headers=headers, json={"quantity": 4})
    result = client.get(f"/v1/stores/{snapshot['store']['id']}/analytics", headers=headers).json()
    assert result["inventory"][0]["quantity"] == 4


def test_replay_provenance_never_contributes_to_live_analytics(store):
    client, app, headers, snapshot, _ = store
    sid = snapshot["store"]["id"]
    app.state.db.event(
        "a",
        sid,
        "visit",
        {
            "started_at": "2026-10-24T00:00:00Z",
            "ended_at": "2026-10-24T00:01:00Z",
            "shelf_id": snapshot["shelves"][0]["id"],
            "provenance": "labeled_replay",
        },
    )
    result = client.get(
        f"/v1/stores/{sid}/analytics",
        headers=headers,
        params={"start": "2026-10-23T00:00:00Z", "end": "2026-10-25T00:00:00Z"},
    ).json()
    assert result["visits"] == 0
    assert result["total_dwell_seconds"] == 0


def test_monitoring_uses_device_store_shelf_snapshot_and_validates_settings(store):
    from test_api import calibration

    client, _, headers, snapshot, _ = store
    sid, shelf_id = snapshot["store"]["id"], snapshot["shelves"][0]["id"]
    cal = calibration(client, headers, snapshot).json()
    body = {
        "calibration_id": cal["id"],
        "settings": {"dwell_cutoff_sec": 8},
        "store_settings": {"dwell_cutoff_sec": 4},
        "shelf_settings": {shelf_id: {"dwell_cutoff_sec": 6, "monitoring_sample_fps": 10}},
    }
    invalid = client.post(
        f"/v1/stores/{sid}/monitoring",
        headers=headers,
        json={**body, "settings": {"active_ai_provider": "fake"}},
    )
    assert invalid.status_code == 422
    response = client.post(f"/v1/stores/{sid}/monitoring", headers=headers, json=body)
    assert response.status_code == 201, response.text
    assert response.json()["thresholds"]["dwell_cutoff_sec"] == 4
    assert response.json()["shelf_thresholds"][shelf_id]["dwell_cutoff_sec"] == 6
    assert response.json()["shelf_thresholds"][shelf_id]["monitoring_sample_fps"] == 10


@pytest.mark.parametrize(
    "provider,field_prefix", [("openrouter", "openrouter"), ("nvidia-nim", "nvidia_nim")]
)
def test_named_credentials_work_when_same_provider_is_environment_default(
    tmp_path, provider, field_prefix
):
    from shelfsight.api import create_app

    app = create_app(
        Settings(
            _env_file=None,
            runtime_dir=tmp_path,
            vision_provider=provider,
            vision_api_key="",
            vision_model="",
            **{
                f"{field_prefix}_api_key": "test-only-key",
                f"{field_prefix}_model": "test-model",
            },
        )
    )
    assert app.state.vision_providers[field_prefix].available
    app.state.db.close()


def test_only_known_legacy_canonical_path_is_migrated(tmp_path):
    from shelfsight.config import ROOT

    assert Settings(_env_file=None, config_path=ROOT / "config/defaults.json").config_path == (
        ROOT / "app/assets/defaults.json"
    )
    custom = tmp_path / "custom.json"
    assert Settings(_env_file=None, config_path=custom).config_path == custom


def test_standalone_shelf_cannot_start_remote_monitoring(store):
    from test_api import calibration

    client, _, headers, snapshot, _ = store
    cal = calibration(client, headers, snapshot).json()
    response = client.post(
        f"/v1/stores/{snapshot['store']['id']}/monitoring",
        headers=headers,
        json={
            "calibration_id": cal["id"],
            "shelf_settings": {
                snapshot["shelves"][0]["id"]: {"execution_mode": "standalone_mobile"},
            },
        },
    )
    assert response.status_code == 409


@pytest.mark.parametrize("provider", ["nvidia-nim", "openrouter"])
def test_named_provider_endpoint_overrides_legacy_endpoint(tmp_path, provider):
    from shelfsight.api import create_app

    name = provider.replace("-", "_")
    app = create_app(
        Settings(
            _env_file=None,
            runtime_dir=tmp_path,
            vision_provider=provider,
            vision_api_key="legacy-test-key",
            vision_model="legacy-test-model",
            vision_base_url="https://legacy.example/v1",
            **{
                f"{name}_api_key": "named-test-key",
                f"{name}_model": "named-test-model",
                f"{name}_base_url": "https://configured.example/v1",
            },
        )
    )
    selected = app.state.vision_providers[name]
    assert selected.api_key == "named-test-key"
    assert selected.model == "named-test-model"
    assert selected.base_url == "https://configured.example/v1"
    app.state.db.close()


def test_scan_switches_provider_at_runtime_without_falling_back(store):
    import cv2
    import numpy as np

    class RecordingVision:
        def __init__(self, source, available=True):
            self.source, self.available, self.reason = source, available, "Test provider"
            self.calls = 0

        def scan(self, image):
            self.calls += 1
            return []

    client, app, headers, snapshot, _ = store
    gemini, router = RecordingVision("gemini"), RecordingVision("openrouter")
    app.state.vision_providers.clear()
    app.state.vision_providers.update(
        gemini=gemini, openrouter=router, nvidia_nim=RecordingVision("nvidia_nim", False)
    )
    _, encoded = cv2.imencode(".png", np.zeros((5, 5, 3), dtype=np.uint8))
    path = f"/v1/stores/{snapshot['store']['id']}/scan"
    response = client.post(
        path,
        headers=headers,
        params={"active_ai_provider": "openrouter"},
        files={"file": ("test.png", encoded.tobytes(), "image/png")},
    )
    assert response.status_code == 200, response.text
    assert response.json()["source"] == "openrouter"
    assert router.calls == 1 and gemini.calls == 0
    response = client.post(
        path,
        headers=headers,
        params={"active_ai_provider": "nvidia_nim"},
        files={"file": ("test.png", encoded.tobytes(), "image/png")},
    )
    assert response.status_code == 503
    assert router.calls == 1 and gemini.calls == 0
    # An offline local mode change must override the stale server copy on scan,
    # just as the monitoring configuration snapshot does.
    sid = snapshot["store"]["id"]
    assert (
        client.patch(
            f"/v1/stores/{sid}",
            headers=headers,
            json={"settings": {"execution_mode": "standalone_mobile"}},
        ).status_code
        == 200
    )
    for mode, status in [("remote_server", 200), ("standalone_mobile", 409), ("fake", 422)]:
        response = client.post(
            path,
            headers=headers,
            params={"active_ai_provider": "openrouter", "execution_mode": mode},
            files={"file": ("test.png", encoded.tobytes(), "image/png")},
        )
        assert response.status_code == status, response.text
