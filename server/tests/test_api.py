import base64
import time

import cv2
import numpy as np
import pytest


def test_auth_pair_replay_expiry_and_revoke(environment):
    client, app, pair, detector = environment
    assert client.get("/v1/stores").status_code == 401
    secret, _ = app.state.sessions.issue_pairing()
    body = {"pairing_secret": secret, "device_name": "Owner device"}
    assert (
        client.post("/v1/pair", headers={"Authorization": "Bearer wrong"}, json=body).status_code == 401
    )
    response = client.post("/v1/pair", headers={"Authorization": "Bearer identity-a"}, json=body)
    assert response.status_code == 200
    assert (
        client.post("/v1/pair", headers={"Authorization": "Bearer identity-a"}, json=body).status_code
        == 403
    )
    headers = {"Authorization": "Bearer " + response.json()["session_token"]}
    assert client.get("/v1/session", headers=headers).status_code == 200
    assert client.delete("/v1/session", headers=headers).status_code == 204
    assert client.get("/v1/stores", headers=headers).status_code == 401
    secret, _ = app.state.sessions.issue_pairing()
    app.state.db.execute("UPDATE pairing SET expires_at=0")
    assert (
        client.post(
            "/v1/pair",
            headers={"Authorization": "Bearer identity-a"},
            json={**body, "pairing_secret": secret},
        ).status_code
        == 403
    )


def test_every_object_is_owner_scoped(store, environment):
    client, app, headers, data, detector = store
    other = environment[2]("b")
    store_id, floor_id, shelf_id = data["store"]["id"], data["floors"][0]["id"], data["shelves"][0]["id"]
    assert client.get("/v1/stores", headers=other).json() == {"items": []}
    for path in (
        f"/v1/stores/{store_id}/snapshot",
        f"/v1/stores/{store_id}/analytics",
        f"/v1/stores/{store_id}/events",
    ):
        assert client.get(path, headers=other).status_code == 404
    assert (
        client.patch(f"/v1/floors/{floor_id}", json={"name": "stolen"}, headers=other).status_code == 404
    )
    assert (
        client.patch(f"/v1/shelves/{shelf_id}", json={"name": "stolen"}, headers=other).status_code
        == 404
    )
    assert client.delete(f"/v1/stores/{store_id}", headers=other).status_code == 404
    assert (
        client.get(f"/v1/stores/{store_id}/snapshot", headers=headers).json()["store"]["name"]
        == "Willow Supplies"
    )


def test_dynamic_settings_geometry_and_validation(store):
    client, app, headers, data, detector = store
    sid, shelf = data["store"]["id"], data["shelves"][0]
    assert len(data["shelves"]) == 2
    assert (
        client.patch(
            f"/v1/stores/{sid}", headers=headers, json={"settings": {"dwell_seconds": 3, "low_stock": 7}}
        ).status_code
        == 200
    )
    assert (
        client.patch(
            f"/v1/shelves/{shelf['id']}", headers=headers, json={"settings": {"low_stock": 2}}
        ).status_code
        == 200
    )
    invalid = client.patch(f"/v1/stores/{sid}", headers=headers, json={"settings": {"made_up": 9}})
    assert invalid.status_code == 422
    assert (
        client.patch(
            f"/v1/stores/{sid}", headers=headers, json={"settings": {"minimum_confidence": 2}}
        ).status_code
        == 422
    )
    geometry = {"x": 2, "y": 1, "width": 3, "length": 1, "rotation": 90}
    assert client.patch(f"/v1/shelves/{shelf['id']}", headers=headers, json=geometry).status_code == 200
    assert client.patch(f"/v1/shelves/{shelf['id']}", headers=headers, json={"x": 20}).status_code == 422
    assert (
        client.patch(
            f"/v1/floors/{data['floors'][0]['id']}", headers=headers, json={"width": 1}
        ).status_code
        == 422
    )
    assert client.patch(f"/v1/stores/{sid}", headers=headers, json={"unit": "ft"}).status_code == 200
    snapshot = client.get(f"/v1/stores/{sid}/snapshot", headers=headers).json()
    assert snapshot["floors"][0]["width"] == pytest.approx(12 / 0.3048)


def add_item(client, headers, data, *, name="=unsafe formula"):
    sid, shelf_id = data["store"]["id"], data["shelves"][0]["id"]
    product = client.post(
        f"/v1/stores/{sid}/products",
        headers=headers,
        json={"name": name, "price_minor": 250, "currency": "USD"},
    )
    assert product.status_code == 201, product.text
    product = product.json()
    response = client.post(
        f"/v1/shelves/{shelf_id}/items",
        headers=headers,
        json={"product_id": product["id"], "row": 1, "slot": 1, "quantity": 13},
    )
    assert response.status_code == 201, response.text
    return product, response.json()


def test_event_only_inventory_analytics_slot_collision_and_csv(store):
    client, app, headers, data, detector = store
    sid = data["store"]["id"]
    empty = client.get(f"/v1/stores/{sid}/analytics", headers=headers).json()
    assert empty["visits"] == 0 and empty["inventory"] == [] and empty["coverage_seconds"] == 0
    assert empty["capabilities"]["sales"] is False and empty["capabilities"]["pickup"] is False
    product, item = add_item(client, headers, data)
    assert (
        client.post(
            f"/v1/shelves/{item['shelf_id']}/items",
            headers=headers,
            json={"product_id": product["id"], "row": 1, "slot": 1, "quantity": 1},
        ).status_code
        == 409
    )
    assert (
        client.patch(f"/v1/items/{item['id']}", headers=headers, json={"quantity": -1}).status_code
        == 422
    )
    assert (
        client.patch(f"/v1/items/{item['id']}", headers=headers, json={"quantity": 4}).status_code == 200
    )
    result = client.get(f"/v1/stores/{sid}/analytics", headers=headers).json()
    assert result["inventory"][0]["quantity"] == 4
    assert result["visits"] == 0 and result["total_dwell_seconds"] == 0
    # Mutating an object outside event writes cannot invent analytics quantities.
    app.state.db.update("item", item["id"], "a", {"quantity": 999})
    assert (
        client.get(f"/v1/stores/{sid}/analytics", headers=headers).json()["inventory"][0]["quantity"]
        == 4
    )
    csv = client.get(f"/v1/stores/{sid}/analytics/export", headers=headers)
    assert "'=unsafe formula" in csv.text
    events = client.get(f"/v1/stores/{sid}/events", headers=headers).json()["items"]
    assert [e["delta"] for e in events] == [13, -9]
    assert all("provenance" in e and "config_revision" in e for e in events)


def test_bad_barcode_is_data_and_malformed_scan_rejected(store):
    client, app, headers, data, detector = store
    response = client.get(
        "/v1/products/lookup",
        headers=headers,
        params={"barcode": "https://localhost/private?key=secret"},
    )
    assert response.json() == {"found": False, "product": None, "source": "manual"}
    result = client.post(
        f"/v1/stores/{data['store']['id']}/scan",
        headers=headers,
        files={"file": ("bad.jpeg", b"not image", "image/jpeg")},
    )
    assert result.status_code == 422
    result = client.post(
        f"/v1/stores/{data['store']['id']}/scan",
        headers=headers,
        files={"file": ("huge.jpeg", b"x" * (5 * 1024 * 1024 + 1), "image/jpeg")},
    )
    assert result.status_code == 413


def calibration(client, headers, data):
    return client.post(
        f"/v1/stores/{data['store']['id']}/calibrations",
        headers=headers,
        json={
            "orientation": "portraitUp",
            "frame_width": 100,
            "frame_height": 100,
            "zones": [{"shelf_id": data["shelves"][0]["id"], "x": 0, "y": 0, "width": 1, "height": 1}],
        },
    )


def test_overlap_calibration_and_cross_store_rejected(store):
    client, app, headers, data, detector = store
    body = {
        "orientation": "portraitUp",
        "frame_width": 100,
        "frame_height": 100,
        "zones": [
            {"shelf_id": shelf["id"], "x": 0, "y": 0, "width": 0.7, "height": 0.7}
            for shelf in data["shelves"]
        ],
    }
    result = client.post(f"/v1/stores/{data['store']['id']}/calibrations", headers=headers, json=body)
    assert result.status_code == 422
    assert calibration(client, headers, data).status_code == 201


def test_websocket_idempotency_finalization_and_orientation(store):
    client, app, headers, data, detector = store
    sid = data["store"]["id"]
    assert (
        client.patch(
            f"/v1/stores/{sid}", headers=headers, json={"settings": {"dwell_seconds": 0}}
        ).status_code
        == 200
    )
    cal = calibration(client, headers, data).json()
    response = client.post(
        f"/v1/stores/{sid}/monitoring", headers=headers, json={"calibration_id": cal["id"]}
    )
    assert response.status_code == 201, response.text
    session = response.json()
    ok, encoded = cv2.imencode(".jpg", np.zeros((100, 100, 3), dtype=np.uint8))
    image = base64.b64encode(encoded).decode()
    frame = {
        "type": "frame",
        "session_id": session["id"],
        "sequence": 1,
        "captured_at_ms": int(time.time() * 1000) - 300,
        "orientation": "portraitUp",
        "width": 100,
        "height": 100,
        "image_base64": image,
    }
    with client.websocket_connect(f"/v1/monitoring/{session['id']}/stream", headers=headers) as ws:
        ws.send_json(frame)
        ack = ws.receive_json()
        assert ack["type"] == "ack" and len(ack["tracks"]) == 1
        ws.send_json(frame)
        assert ws.receive_json()["duplicate"] is True
        ws.send_json({**frame, "sequence": 2, "captured_at_ms": frame["captured_at_ms"] + 200})
        ack = ws.receive_json()
        assert ack["stats"]["frames"] == 2 and ack["stats"]["cloud_requests"] == 0
    stopped = client.post(f"/v1/monitoring/{session['id']}/stop", headers=headers)
    assert stopped.json()["status"] == "interrupted"
    assert (
        client.post(f"/v1/monitoring/{session['id']}/stop", headers=headers).json()["id"]
        == session["id"]
    )
    events = client.get(f"/v1/stores/{sid}/events", headers=headers).json()["items"]
    assert len([event for event in events if event["type"] == "visit"]) == 1
    result = client.get(f"/v1/stores/{sid}/analytics", headers=headers).json()
    assert result["visits"] == 1 and result["coverage_seconds"] == pytest.approx(0.2)
    assert result["total_dwell_seconds"] == pytest.approx(0.2)
    new = client.post(
        f"/v1/stores/{sid}/monitoring", headers=headers, json={"calibration_id": cal["id"]}
    ).json()
    with client.websocket_connect(f"/v1/monitoring/{new['id']}/stream", headers=headers) as ws:
        ws.send_json({**frame, "session_id": new["id"], "orientation": "landscapeLeft"})
        error = ws.receive_json()
        assert error["type"] == "error" and "recalibrate" in error["detail"]


def test_analytics_interval_clipping_union_and_date_boundaries(store):
    client, app, headers, data, detector = store
    db, sid, shelf = app.state.db, data["store"]["id"], data["shelves"][0]["id"]
    for start, end in (
        ("2026-10-21T23:59:58Z", "2026-10-22T00:00:03Z"),
        ("2026-10-22T00:00:01Z", "2026-10-22T00:00:04Z"),
    ):
        db.event("a", sid, "coverage", {"started_at": start, "ended_at": end, "shelf_ids": [shelf]})
    db.event(
        "a",
        sid,
        "visit",
        {
            "shelf_id": shelf,
            "started_at": "2026-10-21T23:59:59Z",
            "ended_at": "2026-10-22T00:00:02Z",
            "dwell_seconds": 3,
        },
    )
    params = {"start": "2026-10-22T00:00:00Z", "end": "2026-10-23T00:00:00Z"}
    result = client.get(f"/v1/stores/{sid}/analytics", headers=headers, params=params).json()
    assert (
        result["coverage_seconds"] == 4 and result["total_dwell_seconds"] == 2 and result["visits"] == 1
    )
    assert result["shelves"][0]["exposure_seconds"] == 4
    assert (
        client.get(
            f"/v1/stores/{sid}/analytics",
            headers=headers,
            params={"start": "2026-10-22", "end": params["end"]},
        ).status_code
        == 422
    )


def test_validation_never_echoes_secrets(environment):
    client, app, pair, detector = environment
    secret = "confidential-invalid-secret"  # noqa: S105 - test-only malformed input, not a credential.
    result = client.post(
        "/v1/pair", json={"pairing_secret": secret, "device_name": "", "secret": secret}
    )
    assert result.status_code == 422
    assert secret not in result.text
