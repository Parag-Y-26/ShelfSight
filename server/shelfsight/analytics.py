"""Every metric originates in the append-only event ledger."""

from __future__ import annotations

import csv
import io
from datetime import UTC, datetime

from fastapi import HTTPException

from .config import BusinessConfig
from .db import Database, utc_now


def parse_time(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Timezone required")
        return parsed.astimezone(UTC)
    except (ValueError, TypeError) as exc:
        raise HTTPException(422, "Dates must be ISO timestamps with an explicit timezone") from exc


def union_duration(intervals: list[tuple[float, float]]) -> float:
    if not intervals:
        return 0.0
    start, end = sorted(intervals)[0]
    total = 0.0
    for a, b in sorted(intervals)[1:]:
        if a <= end:
            end = max(end, b)
        else:
            total += end - start
            start, end = a, b
    return total + end - start


def summarize(
    db: Database,
    config: BusinessConfig,
    owner: str,
    store_id: str,
    start: str,
    end: str,
    capabilities: dict,
) -> dict:
    store = db.get("store", store_id, owner)
    a, b = parse_time(start).timestamp(), parse_time(end).timestamp()
    if b <= a:
        raise HTTPException(422, "Analytics end must be later than start")
    shelves = {
        s["id"]: {
            "shelf_id": s["id"],
            "name": s["name"],
            "visits": 0,
            "dwell_seconds": 0.0,
            "exposure_seconds": 0.0,
        }
        for s in db.list("shelf", owner, store_id)
    }
    shelf_objects = {s["id"]: s for s in db.list("shelf", owner, store_id)}
    visits, dwell = 0, 0.0
    coverage, exposure, inventory = [], {}, {}
    for event in db.events(owner, store_id):
        if event.get("provenance") == "labeled_replay":
            continue
        kind = event["type"]
        if kind in {"visit", "coverage"}:
            event_a, event_b = (
                parse_time(event["started_at"]).timestamp(),
                parse_time(event["ended_at"]).timestamp(),
            )
            left, right = max(a, event_a), min(b, event_b)
            if right <= left:
                continue
            if kind == "visit":
                visits += 1
                dwell += right - left
                if event["shelf_id"] in shelves:
                    shelves[event["shelf_id"]]["visits"] += 1
                    shelves[event["shelf_id"]]["dwell_seconds"] += right - left
            else:
                coverage.append((left, right))
                for shelf_id in event.get("shelf_ids", []):
                    exposure.setdefault(shelf_id, []).append((left, right))
        elif kind == "inventory_adjustment" and parse_time(event["server_timestamp"]).timestamp() < b:
            item_id = event["item_id"]
            if item_id not in inventory:
                inventory[item_id] = {
                    "item_id": item_id,
                    "shelf_id": event["shelf_id"],
                    "product_id": event["product_id"],
                    "name": event["product_name"],
                    "quantity": 0,
                    "price_minor": event.get("price_minor"),
                    "currency": event.get("currency"),
                    "last_corrected_at": event["server_timestamp"],
                }
            inventory[item_id]["quantity"] += event["delta"]
            inventory[item_id]["last_corrected_at"] = event["server_timestamp"]
            inventory[item_id]["name"] = event["product_name"]
            inventory[item_id]["price_minor"] = event.get("price_minor")
            inventory[item_id]["currency"] = event.get("currency")
    for shelf_id, intervals in exposure.items():
        if shelf_id in shelves:
            shelves[shelf_id]["exposure_seconds"] = union_duration(intervals)
    for item in inventory.values():
        item["low_stock_threshold"] = config.thresholds(store, shelf_objects.get(item["shelf_id"]))[
            "low_stock_threshold"
        ]
    return {
        "start": start,
        "end": end,
        "coverage_seconds": union_duration(coverage),
        "visits": visits,
        "total_dwell_seconds": dwell,
        "shelves": sorted(shelves.values(), key=lambda s: (-s["visits"], s["name"])),
        "inventory": list(inventory.values()),
        "capabilities": capabilities,
        "generated_at": utc_now(),
    }


def safe_cell(value):
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@", "\t", "\r", "\n")):
        return "'" + value
    return value


def export_csv(summary: dict) -> str:
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(["metric", "name", "value", "unit", "timestamp"])
    writer.writerow(["coverage", "", summary["coverage_seconds"], "seconds", summary["generated_at"]])
    writer.writerow(["visits", "", summary["visits"], "visits", summary["generated_at"]])
    writer.writerow(["dwell", "", summary["total_dwell_seconds"], "seconds", summary["generated_at"]])
    for shelf in summary["shelves"]:
        writer.writerow(["shelf_visits", safe_cell(shelf["name"]), shelf["visits"], "visits", ""])
        writer.writerow(["shelf_dwell", safe_cell(shelf["name"]), shelf["dwell_seconds"], "seconds", ""])
        writer.writerow(
            ["shelf_exposure", safe_cell(shelf["name"]), shelf["exposure_seconds"], "seconds", ""]
        )
    for item in summary["inventory"]:
        writer.writerow(
            [
                "recorded_inventory",
                safe_cell(item["name"]),
                item["quantity"],
                "units",
                item["last_corrected_at"],
            ]
        )
    return output.getvalue()
