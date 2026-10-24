"""Typed choice/score/noul with conservative ledger gates and optional Laya HTTP."""

from __future__ import annotations

import math
import time
from datetime import UTC, datetime
from statistics import median
from urllib.parse import urlsplit

from .ai_contracts import bounded_json_post
from .analytics import union_duration
from .config import BusinessConfig


class LayaDecisionService:
    def __init__(self, config: BusinessConfig, endpoint: str = "", api_key: str = "", *, post=None):
        self.config, self.api_key = config, api_key
        self.post = post or bounded_json_post
        self.endpoint = ""
        self._unavailable_until = 0.0
        if endpoint:
            uri = urlsplit(endpoint)
            if (
                uri.username
                or uri.password
                or uri.query
                or uri.fragment
                or not uri.hostname
                or not (
                    uri.scheme == "https"
                    or uri.scheme == "http"
                    and uri.hostname in {"localhost", "127.0.0.1", "::1"}
                )
            ):
                raise ValueError("LAYA_ENDPOINT_URL must be HTTPS or loopback HTTP")
            self.endpoint = endpoint.rstrip("/")
            if not self.endpoint.endswith("/v1/systemone"):
                self.endpoint += "/v1/systemone"

    def _remote(self, state: dict, questions: dict) -> dict | None:
        if not self.endpoint or time.monotonic() < self._unavailable_until:
            return None
        try:
            headers = {"Content-Type": "application/json"}
            if self.api_key:
                headers["Authorization"] = f"Bearer {self.api_key}"
            result = self.post(
                self.endpoint,
                headers,
                {"state": state, "questions": questions},
                self.config.data["ai"]["limits"]["laya_timeout_seconds"],
            )
            if result.get("usage", {}).get("truncated"):
                return None
            answers = result.get("answers")
            return answers if isinstance(answers, dict) else None
        except (ValueError, KeyError, TypeError, OSError, TimeoutError):
            self._unavailable_until = (
                time.monotonic() + self.config.data["ai"]["limits"]["laya_cooldown_seconds"]
            )
            return None
        except Exception:
            self._unavailable_until = (
                time.monotonic() + self.config.data["ai"]["limits"]["laya_cooldown_seconds"]
            )
            # HTTP failures must not expose bearer credentials or disable offline rules.
            return None

    def choice(self, task: str, available: list[str], health: dict | None = None) -> dict:
        profiles = self.config.data["ai"]["providers"]
        available = [name for name in profiles if name in available]
        if not available:
            raise ValueError("No AI provider is configured")
        health = health or {}
        ranked = sorted(
            available,
            key=lambda name: (
                health.get(name, {}).get("error_rate", 0),
                health.get(name, {}).get("latency_ms") or 0,
                list(profiles).index(name),
            ),
        )
        selected, source, probabilities = ranked[0], "deterministic_policy", None
        remote = self._remote(
            {"task": task, "provider_health": health, "available_providers": available},
            {
                "route": {
                    "type": "choice",
                    "instructions": "Choose an available provider with low errors and latency.",
                    "criteria": {name: f"Use {name} for {task}" for name in available},
                }
            },
        )
        if remote and isinstance(remote.get("route"), dict):
            answer = remote["route"]
            distribution = answer.get("probabilities")
            valid_distribution = (
                isinstance(distribution, dict)
                and set(distribution) == set(available)
                and all(
                    isinstance(p, (int, float))
                    and not isinstance(p, bool)
                    and math.isfinite(p)
                    and 0 <= p <= 1
                    for p in distribution.values()
                )
                and abs(sum(distribution.values()) - 1) <= 0.001
            )
            if (
                answer.get("type") == "choice"
                and answer.get("choice") in available
                and valid_distribution
                and distribution[answer["choice"]] == max(distribution.values())
                and not answer.get("low_confidence", False)
            ):
                selected, source = answer["choice"], "laya_model_reported"
                probabilities = distribution
        profile = profiles[selected]
        model = profile["vision_model" if task == "shelf_scan" else "decision_model"]
        return {
            "type": "choice",
            "choice": selected,
            "provider": selected,
            "model": model,
            "calibration_status": source,
            "probabilities": probabilities,
            "confidence": probabilities[selected] if probabilities else None,
        }

    def score(self, telemetry: dict) -> dict:
        stock, threshold = telemetry.get("recorded_stock"), telemetry.get("low_stock_threshold")
        defaults = self.config.data["settings"]
        dwell = telemetry.get("median_dwell_sec")
        watch = (
            telemetry.get("visit_count", 0)
            >= telemetry.get("decision_min_visits", defaults["decision_min_visits"])
            and dwell is not None
            and dwell < telemetry.get("dwell_cutoff_sec", defaults["dwell_cutoff_sec"])
        )
        value = (
            2.0
            if stock is not None and threshold is not None and stock <= threshold
            else (1.0 if watch else 0.0)
        )
        return {
            "value": value,
            "type": "score",
            "label": ["normal", "watch", "urgent"][int(value)],
            "calibration_status": "deterministic_policy",
        }

    def noul(self, events: list[dict], shelf: dict, store: dict | None = None, **kwargs) -> dict:
        return self.assess(events, shelf, store, **kwargs)["noul"]

    def assess(
        self,
        events: list[dict],
        shelf: dict,
        store: dict | None = None,
        *,
        now: datetime | None = None,
        device_defaults: dict | None = None,
    ) -> dict:
        now = now or datetime.now(UTC)
        settings = self.config.thresholds(store, shelf, device_defaults)
        ai = self.config.data["ai"]
        valid = []
        seen = set()
        stock = {}
        for event in events:
            if (
                not isinstance(event.get("id"), str)
                or not event["id"]
                or event["id"] in seen
                or not (
                    event.get("shelf_id") == shelf["id"]
                    or event.get("type") == "coverage"
                    and shelf["id"] in event.get("shelf_ids", [])
                )
                or event.get("provenance") not in ai["evidence_provenance"]
            ):
                continue
            try:
                at = datetime.fromisoformat(event["server_timestamp"].replace("Z", "+00:00"))
                age = (now - at).total_seconds()
                if (
                    age >= 0
                    and event.get("type") == "inventory_adjustment"
                    and isinstance(event.get("item_id"), str)
                ):
                    quantity = event.get("quantity", event.get("new_quantity"))
                    if isinstance(quantity, int) and not isinstance(quantity, bool) and quantity >= 0:
                        previous = stock.get(event["item_id"])
                        if previous is None or at >= previous[2]:
                            stock[event["item_id"]] = (quantity, event["id"], at, age)
                if not 0 <= age <= ai["decision_policy"]["evidence_max_age_seconds"]:
                    continue
            except (KeyError, ValueError, TypeError):
                continue
            seen.add(event["id"])
            valid.append(event)
        visits, coverage, incomplete = [], [], []
        for event in valid:
            if event["type"] == "visit":
                dwell = event.get("dwell_seconds")
                if (
                    isinstance(dwell, (int, float))
                    and not isinstance(dwell, bool)
                    and math.isfinite(dwell)
                    and dwell >= 0
                ):
                    if event.get("incomplete") is True:
                        incomplete.append(event)
                    elif event.get("incomplete") is False:
                        visits.append(event)
            elif event["type"] == "coverage" and event.get("incomplete") is False:
                try:
                    start = datetime.fromisoformat(event["started_at"].replace("Z", "+00:00"))
                    end = datetime.fromisoformat(event["ended_at"].replace("Z", "+00:00"))
                    duration = (end - start).total_seconds()
                    if duration > 0:
                        coverage.append((event, start.timestamp(), end.timestamp()))
                except (KeyError, ValueError, TypeError):
                    pass
        known_items = set(shelf.get("known_item_ids", stock.keys()))
        complete = (
            bool(known_items)
            and known_items == stock.keys()
            and all(
                stock[item][3] <= ai["decision_policy"]["evidence_max_age_seconds"]
                for item in known_items
            )
        )
        stock_ids = [stock[item][1] for item in sorted(known_items) if item in stock]
        recorded = sum(stock[item][0] for item in known_items) if complete else None
        telemetry = {
            "visit_count": len(visits),
            "median_dwell_sec": median(event["dwell_seconds"] for event in visits) if visits else None,
            "recorded_stock": recorded,
            "stock_evidence_complete": complete,
            "low_stock_threshold": settings["low_stock_threshold"],
            "dwell_cutoff_sec": settings["dwell_cutoff_sec"],
            "decision_min_visits": settings["decision_min_visits"],
        }
        enough = (
            len(visits) >= settings["decision_min_visits"]
            and union_duration([(value[1], value[2]) for value in coverage])
            >= settings["decision_min_coverage_sec"]
        )
        evidence = {
            "restock_alert": (
                recorded is not None,
                recorded is not None and recorded <= settings["low_stock_threshold"],
                stock_ids,
            ),
            "planogram_swap": (
                enough,
                enough and telemetry["median_dwell_sec"] < settings["dwell_cutoff_sec"],
                [e["id"] for e in visits] + [e[0]["id"] for e in coverage],
            ),
            "calibration_check": (bool(incomplete), bool(incomplete), [e["id"] for e in incomplete]),
        }
        noul = {
            key: {
                "p_true": float(yes)
                if supported and len(ids) <= ai["decision_policy"]["max_event_ids"]
                else None,
                "type": "noul",
                "event_ids": ids[: ai["decision_policy"]["max_event_ids"]],
                "eligible": supported and yes and len(ids) <= ai["decision_policy"]["max_event_ids"],
                "calibration_status": "deterministic_policy",
            }
            for key, (supported, yes, ids) in evidence.items()
        }
        questions = {
            key: {"type": "noul", "instructions": f"Does the verified evidence justify {key}?"}
            for key, (supported, _, _) in evidence.items()
            if supported
        }
        questions["urgency"] = {
            "type": "score",
            "instructions": "Rate merchandising urgency.",
            "criteria": ["normal", "watch", "urgent"],
        }
        remote = (
            self._remote(
                {
                    "telemetry": telemetry,
                    "evidence_gates": {
                        key: supported and yes for key, (supported, yes, _) in evidence.items()
                    },
                },
                questions,
            )
            if valid
            else None
        )
        if remote:
            for key, result in noul.items():
                answer = remote.get(key, {})
                if not isinstance(answer, dict):
                    continue
                p = answer.get("noul")
                # A model can suppress an eligible alert; it cannot create eligibility.
                if (
                    result["p_true"] == 1
                    and answer.get("type") == "noul"
                    and isinstance(p, (int, float))
                    and not isinstance(p, bool)
                    and math.isfinite(p)
                    and 0 <= p <= 1
                    and not answer.get("low_confidence", False)
                ):
                    result.update(p_true=p, calibration_status="laya_model_reported_unvalidated")
        typed_score = self.score(telemetry)
        answer = remote.get("urgency") if remote else None
        if isinstance(answer, dict):
            value = answer.get("score")
            if (
                answer.get("type") == "score"
                and isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value)
                and 0 <= value <= typed_score["value"]
                and not answer.get("low_confidence", False)
            ):
                typed_score = {
                    "value": value,
                    "label": "urgent" if value >= 1.5 else "watch" if value >= 0.5 else "normal",
                    "calibration_status": "laya_model_reported_unvalidated",
                }
        return {
            "shelf_id": shelf["id"],
            "telemetry": telemetry,
            "score": typed_score,
            "noul": noul,
            "probability_threshold": settings["decision_probability_threshold"],
        }
