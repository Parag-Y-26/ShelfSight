"""Evaluate actual exported shelf visits against human-labelled intervals.

No sample events are generated. JSON input is a list, or an object with an
``items`` list. Intervals contain shelf_id, started_at, ended_at (ISO 8601).
Optional --frames input is a list of acknowledgements with processing_ms.
"""
from __future__ import annotations

import argparse
import json
import math
from datetime import datetime
from pathlib import Path
from statistics import median
from typing import Any


def timestamp(value: str) -> float:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Evaluation timestamps must include a timezone")
    return parsed.timestamp()


def intervals(document: Any) -> list[dict[str, Any]]:
    records = document.get("items", []) if isinstance(document, dict) else document
    if not isinstance(records, list):
        raise ValueError("Input must be an event list or an object with items")
    result = []
    for record in records:
        if record.get("type", "visit") != "visit":
            continue
        data = record.get("data", record)
        start = timestamp(data["started_at"])
        end = timestamp(data["ended_at"])
        if end <= start:
            raise ValueError("Visit end must be later than start")
        result.append({"shelf_id": record["shelf_id"], "start": start, "end": end})
    return result


def overlap(first: dict[str, Any], second: dict[str, Any]) -> float:
    if first["shelf_id"] != second["shelf_id"]:
        return 0.0
    intersection = max(0.0, min(first["end"], second["end"]) - max(first["start"], second["start"]))
    union = max(first["end"], second["end"]) - min(first["start"], second["start"])
    return intersection / union


def evaluate(predicted: list[dict[str, Any]], truth: list[dict[str, Any]], minimum_iou: float) -> dict[str, Any]:
    if not 0 < minimum_iou <= 1:
        raise ValueError("Minimum interval IoU must be in (0, 1]")
    # Maximum-cardinality bipartite matching avoids undercounting valid matches
    # when a greedy choice steals the only valid partner for another visit.
    edges = {index: sorted(((overlap(p, t), j) for j, t in enumerate(truth) if overlap(p, t) >= minimum_iou), reverse=True)
             for index, p in enumerate(predicted)}
    assigned: dict[int, int] = {}

    def match(index: int, visited: set[int]) -> bool:
        for _, target in edges[index]:
            if target in visited:
                continue
            visited.add(target)
            if target not in assigned or match(assigned[target], visited):
                assigned[target] = index
                return True
        return False

    for index in range(len(predicted)):
        match(index, set())
    count = len(assigned)
    errors = [abs((predicted[p]["end"] - predicted[p]["start"]) - (truth[t]["end"] - truth[t]["start"])) for t, p in assigned.items()]
    precision = count / len(predicted) if predicted else None
    recall = count / len(truth) if truth else None
    return {"predicted_visits": len(predicted), "labelled_visits": len(truth), "matched_visits": count,
            "false_positives": len(predicted) - count, "false_negatives": len(truth) - count,
            "precision": precision, "recall": recall, "median_dwell_error_seconds": median(errors) if errors else None,
            "minimum_interval_iou": minimum_iou, "source": "human-labelled intervals compared with actual event export"}


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    rank = (len(values) - 1) * fraction
    lower, upper = math.floor(rank), math.ceil(rank)
    return values[lower] + (values[upper] - values[lower]) * (rank - lower)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--truth", type=Path, required=True)
    parser.add_argument("--frames", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--minimum-iou", type=float, default=0.5)
    args = parser.parse_args()
    result = evaluate(intervals(json.loads(args.predictions.read_text(encoding="utf-8"))),
                      intervals(json.loads(args.truth.read_text(encoding="utf-8"))), args.minimum_iou)
    if args.frames:
        frames = json.loads(args.frames.read_text(encoding="utf-8"))
        latencies = [float(frame["processing_ms"]) for frame in frames]
        if any(not math.isfinite(value) or value < 0 for value in latencies):
            raise ValueError("Frame latency must be finite and non-negative")
        result["processing_ms"] = {"samples": len(latencies), "p50": percentile(latencies, .5), "p95": percentile(latencies, .95)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
