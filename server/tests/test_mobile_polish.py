"""Phase 4 uses explicit test inputs; no fixtures enter production paths."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Event

import pytest
from pydantic import ValidationError

from shelfsight.geometry import valid_polygon, zone_contains, zones_overlap
from shelfsight.schemas import CalibrationInput


def test_data_wipe_rejects_product_request_that_outlives_parent(store, monkeypatch):
    client, app, headers, snapshot, _ = store
    entered, resume = Event(), Event()

    def slow_validation(*args):
        entered.set()
        assert resume.wait(10)

    monkeypatch.setattr("shelfsight.api.decode_image", slow_validation)
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(
            client.post,
            f"/v1/stores/{snapshot['store']['id']}/products",
            headers=headers,
            json={"name": "Private counted product", "image_base64": "dGVzdA=="},
        )
        try:
            assert entered.wait(10)
            assert client.delete("/v1/stores", headers=headers).status_code == 204
        finally:
            resume.set()
        assert pending.result(timeout=10).status_code == 404
    assert not app.state.db.execute("SELECT id FROM objects WHERE owner=?", ("a",)).fetchall()


def test_remote_recent_ledger_bound_is_validated_and_applied_before_transfer(store):
    client, app, headers, snapshot, _ = store
    sid = snapshot["store"]["id"]
    events = [app.state.db.event("a", sid, "inventory_adjustment", {"quantity": n}) for n in range(4)]
    result = client.get(f"/v1/stores/{sid}/events?limit=2", headers=headers)
    assert result.status_code == 200
    assert [e["id"] for e in result.json()["items"]] == [e["id"] for e in events[-2:]]
    assert client.get(f"/v1/stores/{sid}/events?limit=0", headers=headers).status_code == 422
    assert (
        client.get(
            f"/v1/stores/{sid}/events?limit=2&after={events[0]['id']}", headers=headers
        ).status_code
        == 422
    )


def test_atomic_planogram_initial_stock_and_owner_scoped_citations(store):
    client, app, headers, snapshot, _ = store
    sid, shelf = snapshot["store"]["id"], snapshot["shelves"][0]["id"]
    product = client.post(
        f"/v1/stores/{sid}/products", headers=headers, json={"name": "Verified test product"}
    ).json()
    first = client.post(
        f"/v1/shelves/{shelf}/items",
        headers=headers,
        json={"product_id": product["id"], "row": 1, "slot": 1, "quantity": 2},
    ).json()
    second = client.post(
        f"/v1/shelves/{shelf}/items",
        headers=headers,
        json={"product_id": product["id"], "row": 1, "slot": 2, "quantity": 3},
    ).json()
    result = client.post(
        f"/v1/shelves/{shelf}/planogram",
        headers=headers,
        json={
            "items": [
                {"id": first["id"], "row": 1, "slot": 2, "quantity": 2},
                {"id": second["id"], "row": 1, "slot": 1, "quantity": 3},
            ]
        },
    )
    assert result.status_code == 200, result.text
    events = app.state.db.events("a", sid)
    assert events[0]["event_type"] == "INITIAL_STOCK"
    assert events[-1]["slot"] == 1
    citation = client.get(f"/v1/stores/{sid}/events/{events[0]['id']}", headers=headers)
    assert citation.status_code == 200
    assert citation.json()["quantity"] == 2
    collision = client.post(
        f"/v1/shelves/{shelf}/planogram",
        headers=headers,
        json={
            "items": [
                {"id": first["id"], "row": 1, "slot": 1, "quantity": 2},
            ]
        },
    )
    assert collision.status_code == 409
    assert len(app.state.db.events("a", sid)) == 4
    assert client.get(f"/v1/stores/{sid}/events/{events[0]['id']}").status_code == 401


def test_sqlite_analytics_has_observed_mean_median_and_unmeasured_capabilities(store):
    client, app, headers, snapshot, _ = store
    sid, shelf = snapshot["store"]["id"], snapshot["shelves"][0]["id"]
    start = datetime(2026, 1, 1, tzinfo=UTC)
    for seconds in (10, 30):
        app.state.db.event(
            "a",
            sid,
            "visit",
            {
                "shelf_id": shelf,
                "started_at": start.isoformat(),
                "ended_at": (start + timedelta(seconds=seconds)).isoformat(),
                "dwell_seconds": seconds,
                "provenance": "live_camera",
            },
        )
    app.state.db.event(
        "a",
        sid,
        "visit",
        {
            "shelf_id": shelf,
            "started_at": start.isoformat(),
            "ended_at": (start + timedelta(seconds=100)).isoformat(),
            "provenance": "labeled_replay",
        },
    )
    result = client.get(
        f"/v1/stores/{sid}/analytics",
        headers=headers,
        params={"start": start.isoformat(), "end": (start + timedelta(days=1)).isoformat()},
    ).json()
    assert result["visits"] == 2
    assert result["mean_dwell_seconds"] == result["median_dwell_seconds"] == 20
    assert result["shelves"][0]["median_dwell_seconds"] == 20
    assert not result["capabilities"]["pickup"] and not result["capabilities"]["sales"]
    csv = client.get(
        f"/v1/stores/{sid}/analytics/export",
        headers=headers,
        params={"start": start.isoformat(), "end": (start + timedelta(days=1)).isoformat()},
    )
    assert "median_dwell" in csv.text


def test_delete_all_preserves_other_owner_and_metric_geometry(store):
    client, app, headers, snapshot, _ = store
    sid = snapshot["store"]["id"]
    assert snapshot["floors"][0]["width_m"] == 12
    assert client.patch(f"/v1/stores/{sid}", headers=headers, json={"unit": "ft"}).status_code == 200
    current = client.get(f"/v1/stores/{sid}/snapshot", headers=headers).json()
    assert current["floors"][0]["width_m"] == 12
    other = app.state.db.create("store", "owner-b", "", {"name": "Other profile"})
    assert client.delete("/v1/stores", headers=headers).status_code == 204
    assert client.get("/v1/stores", headers=headers).json()["items"] == []
    assert app.state.db.get("store", other["id"], "owner-b")["name"] == "Other profile"


def test_convex_polygon_calibration_rejects_overlap_and_tracks_inside_only():
    triangle = {
        "shelf_id": "a",
        "x": 0,
        "y": 0,
        "width": 1,
        "height": 1,
        "polygon": [[0, 0], [1, 0], [0, 1]],
    }
    assert valid_polygon(triangle["polygon"])
    assert zone_contains(triangle, 0.2, 0.7)
    assert not zone_contains(triangle, 0.8, 0.8)
    separate = {
        "shelf_id": "b",
        "x": 0.6,
        "y": 0.6,
        "width": 0.4,
        "height": 0.4,
        "polygon": [[1, 1], [1, 0.6], [0.6, 1]],
    }
    assert not zones_overlap(triangle, separate)
    body = {
        "orientation": "portraitUp",
        "frame_width": 480,
        "frame_height": 640,
        "zones": [triangle, separate],
    }
    assert CalibrationInput.model_validate(body)
    with pytest.raises(ValidationError):
        CalibrationInput.model_validate({**body, "zones": [triangle, {**triangle, "shelf_id": "b"}]})
    assert not valid_polygon([[0, 0], [1, 1], [0, 1], [1, 0]])
