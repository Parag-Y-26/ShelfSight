from datetime import UTC, datetime, timedelta

from shelfsight.config import BusinessConfig, Settings
from shelfsight.laya_router import LayaDecisionService
from shelfsight.providers import AutonomousDecisionEngine


def service():
    return LayaDecisionService(BusinessConfig(Settings(_env_file=None).config_path))


def test_choice_considers_errors_latency_and_model_checkpoints():
    choice = service().choice(
        "shelf_scan",
        ["gemini", "nvidia_nim"],
        {
            "gemini": {"error_rate": 1, "latency_ms": 50},
            "nvidia_nim": {"error_rate": 0, "latency_ms": 500},
        },
    )
    assert choice["provider"] == "nvidia_nim"
    assert choice["model"] == "meta/llama-4-maverick-17b-128e-instruct"
    assert choice["calibration_status"] == "deterministic_policy"


def test_noul_abstains_without_evidence_and_restock_requires_stock_event():
    laya = service()
    evidence = laya.assess([], {"id": "s", "settings": {}}, now=datetime.now(UTC))
    assert all(value["p_true"] is None for value in evidence["noul"].values())
    event = {
        "id": "stock-1",
        "shelf_id": "s",
        "type": "inventory_adjustment",
        "item_id": "i",
        "delta": 2,
        "quantity": 2,
        "provenance": "user_input",
        "server_timestamp": datetime.now(UTC).isoformat(),
    }
    evidence = laya.assess([event], {"id": "s", "settings": {}}, now=datetime.now(UTC))
    assert evidence["noul"]["restock_alert"]["p_true"] == 1
    assert evidence["noul"]["restock_alert"]["event_ids"] == ["stock-1"]
    assert evidence["score"]["value"] == 2
    assert (
        laya.assess([{**event, "provenance": "labeled_replay"}], {"id": "s"})["noul"]["restock_alert"][
            "p_true"
        ]
        is None
    )


def test_empty_ledger_never_calls_a_generative_model(store):
    class Router:
        available = True

        def generate(self, *args, **kwargs):
            raise AssertionError("No evidence must mean no LLM call")

    _, app, _, snapshot, _ = store
    engine = AutonomousDecisionEngine(service(), Router())
    plan = engine.decide(app.state.db, "a", snapshot["store"]["id"])
    assert plan["actions"] == []
    assert plan["disclaimer"] == app.state.config.data["ai"]["disclaimer"]


def test_partial_or_stale_stock_abstains_and_zero_threshold_cannot_alert():
    laya = service()
    now = datetime.now(UTC)

    def event(key, quantity, age=0):
        return {
            "id": key,
            "item_id": key,
            "shelf_id": "s",
            "type": "inventory_adjustment",
            "quantity": quantity,
            "provenance": "user_input",
            "server_timestamp": (now - timedelta(days=age)).isoformat(),
        }

    result = laya.assess([event("old", 100, 2), event("recent", 2)], {"id": "s"}, now=now)
    assert result["telemetry"]["recorded_stock"] is None
    assert result["noul"]["restock_alert"]["p_true"] is None
    result = laya.assess(
        [event("recent", 2), event("other-device-item", 100)],
        {"id": "s", "known_item_ids": ["recent"]},
        now=now,
    )
    assert result["noul"]["restock_alert"]["p_true"] is None
    result = laya.assess([event("recent", 2)], {"id": "s", "known_item_ids": ["old", "recent"]}, now=now)
    assert result["noul"]["restock_alert"]["p_true"] is None
    result = laya.assess(
        [event("recent", 100)], {"id": "s", "settings": {"decision_probability_threshold": 0}}, now=now
    )

    class NoRouter:
        available = False

    assert AutonomousDecisionEngine(laya, NoRouter()).from_assessments([result])["actions"] == []


def test_score_uses_stock_visit_and_dwell_rubric():
    laya = service()
    telemetry = {
        "recorded_stock": 100,
        "low_stock_threshold": 5,
        "visit_count": 5,
        "median_dwell_sec": 1,
    }
    assert laya.score(telemetry)["value"] == 1
    assert laya.score({**telemetry, "median_dwell_sec": 10})["value"] == 0
    assert laya.score({**telemetry, "recorded_stock": 2})["value"] == 2
    assert laya.noul([], {"id": "s"})["restock_alert"]["p_true"] is None


def test_bounded_sqlite_ledger_reads_keep_chronological_owner_scope(environment):
    _, app, _, _ = environment
    first = app.state.db.event("a", "s", "inventory_adjustment", {})
    second = app.state.db.event("a", "s", "inventory_adjustment", {})
    app.state.db.event("b", "s", "inventory_adjustment", {})
    assert app.state.db.events("a", "s", limit=1)[0]["id"] == second["id"]
    assert [e["id"] for e in app.state.db.events("a", "s", limit=2)] == [first["id"], second["id"]]


def test_malformed_local_laya_answers_use_deterministic_fallback():
    config = service().config
    for body in [
        {"answers": []},
        {"answers": {"route": []}},
        {"answers": {"route": {"type": "choice", "choice": "unknown"}}},
    ]:
        laya = LayaDecisionService(config, "http://127.0.0.1:8000", post=lambda *args, body=body: body)
        assert laya.choice("shelf_scan", ["gemini"])["provider"] == "gemini"


def test_model_cannot_invent_event_or_shelf_ids_and_fails_over(store):
    import json

    from test_api import add_item

    from shelfsight.vision_compatible import AiProviderRouter

    client, app, headers, snapshot, _ = store
    _, item = add_item(client, headers, snapshot)
    client.patch(f"/v1/items/{item['id']}", headers=headers, json={"quantity": 2})
    sid = snapshot["store"]["id"]
    calls = []

    def post(url, headers, payload, timeout):
        calls.append(url)
        if len(calls) == 1:
            content = json.loads(payload["contents"][0]["parts"][0]["text"])
            wrong = {
                "actions": [
                    {
                        "type": "RESTOCK_ALERT",
                        "shelf_id": "invented-shelf",
                        "event_ids": ["invented-event"],
                    }
                ],
                "disclaimer": content["disclaimer"],
                "requires_review": True,
            }
            return {"candidates": [{"content": {"parts": [{"text": json.dumps(wrong)}]}}]}
        content = json.loads(payload["messages"][1]["content"][0]["text"])
        plan = {
            "actions": content["eligible_actions"],
            "disclaimer": content["disclaimer"],
            "requires_review": True,
        }
        return {"choices": [{"message": {"content": json.dumps(plan)}}]}

    laya = service()
    router = AiProviderRouter(laya.config, credentials={"gemini": "a", "nvidia_nim": "b"}, post=post)
    result = AutonomousDecisionEngine(laya, router).decide(app.state.db, "a", sid)
    assert result["source"] == "nvidia_nim"
    assert len(calls) == 2
    actual = {event["id"] for event in app.state.db.events("a", sid)}
    assert result["actions"][0]["shelf_id"] == item["shelf_id"]
    assert set(result["actions"][0]["event_ids"]) <= actual


def test_laya_wire_types_and_no_model_escalation_without_evidence():
    calls = []

    def post(url, headers, payload, timeout):
        calls.append(payload)
        if "route" in payload["questions"]:
            return {
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "openrouter",
                        "probabilities": {"gemini": 0.1, "openrouter": 0.9},
                    }
                }
            }
        return {
            "answers": {
                "restock_alert": {"type": "noul", "noul": 0.9},
                "planogram_swap": {"type": "noul", "noul": 1},
                "urgency": {"type": "score", "score": 1.5},
            }
        }

    laya = LayaDecisionService(service().config, "http://127.0.0.1:8000", post=post)
    assert laya.choice("shelf_scan", ["gemini", "openrouter"])["provider"] == "openrouter"
    now = datetime.now(UTC)
    result = laya.assess(
        [
            {
                "id": "stock",
                "item_id": "i",
                "shelf_id": "s",
                "type": "inventory_adjustment",
                "quantity": 2,
                "provenance": "user_input",
                "server_timestamp": now.isoformat(),
            }
        ],
        {"id": "s"},
        now=now,
    )
    assert result["noul"]["restock_alert"]["p_true"] == 0.9
    assert result["noul"]["planogram_swap"]["p_true"] is None
    assert result["score"]["value"] == 1.5
    assert calls[0]["questions"]["route"]["type"] == "choice"
    assert calls[1]["questions"]["restock_alert"]["type"] == "noul"
    assert calls[1]["questions"]["urgency"]["criteria"] == ["normal", "watch", "urgent"]


def test_decision_endpoint_is_authenticated_and_owner_scoped(environment):

    client, app, pair, _ = environment
    assert client.post("/v1/stores/unknown/decisions").status_code == 401
    headers_a, headers_b = pair("a"), pair("b")
    owned = app.state.db.create("store", "a", "", {"settings": {}})
    assert client.post(f"/v1/stores/{owned['id']}/decisions", headers=headers_b).status_code == 404
    response = client.post(f"/v1/stores/{owned['id']}/decisions", headers=headers_a)
    assert response.status_code == 200
    assert response.json()["actions"] == []
