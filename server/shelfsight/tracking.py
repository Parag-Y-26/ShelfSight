"""Anonymous geometry tracking and conservative zone visit finalization."""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

from .geometry import zone_contains
from .providers import Detection


def timestamp(seconds: float) -> str:
    return datetime.fromtimestamp(seconds, UTC).isoformat().replace("+00:00", "Z")


def iou(a: tuple, b: tuple) -> float:
    overlap = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - overlap
    return overlap / union if union > 0 else 0


def center_distance(a: tuple, b: tuple) -> float:
    return math.hypot((a[0] + a[2] - b[0] - b[2]) / 2, (a[1] + a[3] - b[1] - b[3]) / 2)


@dataclass
class Track:
    id: int
    bbox: tuple
    last_seen: float
    shelf_id: str | None = None
    entered: float | None = None
    zone_last_seen: float | None = None


class Tracker(Protocol):
    def update(self, detections: list[Detection], now: float) -> list[dict]: ...
    def finish(self, incomplete: bool) -> list[dict]: ...


class ZoneTracker:
    def __init__(self, zones: list[dict], defaults: dict, shelf_settings: dict[str, dict]):
        self.zones, self.defaults, self.settings = zones, defaults, shelf_settings
        self.tracks: dict[int, Track] = {}
        self.next_id = 0
        self.observed_ids: set[int] = set()

    def _settings(self, shelf_id: str | None) -> dict:
        return self.settings.get(shelf_id, self.defaults)

    def _end_visit(self, track: Track, incomplete: bool) -> dict | None:
        if track.shelf_id is None or track.entered is None or track.zone_last_seen is None:
            return None
        duration = max(0, track.zone_last_seen - track.entered)
        result = None
        if duration >= self._settings(track.shelf_id)["dwell_cutoff_sec"]:
            result = {
                "track_id": track.id,
                "shelf_id": track.shelf_id,
                "started_at": timestamp(track.entered),
                "ended_at": timestamp(track.zone_last_seen),
                "dwell_seconds": duration,
                "incomplete": incomplete,
            }
        track.shelf_id, track.entered, track.zone_last_seen = None, None, None
        return result

    def _zone(self, detection: Detection) -> str | None:
        x, y = (detection.bbox[0] + detection.bbox[2]) / 2, detection.bbox[3]
        for zone in self.zones:
            if (
                zone_contains(zone, x, y)
                and detection.confidence
                >= self._settings(zone["shelf_id"])["detection_confidence_threshold"]
            ):
                return zone["shelf_id"]
        return None

    def update(self, detections: list[Detection], now: float) -> list[dict]:
        events = []
        # Expire tracks before association so long gaps cannot be bridged.
        for track_id, track in list(self.tracks.items()):
            if now - track.last_seen > self._settings(track.shelf_id)["tracking_grace_sec"]:
                event = self._end_visit(track, incomplete=True)
                if event:
                    events.append(event)
                del self.tracks[track_id]
        matches = []
        for track_id, track in self.tracks.items():
            thresholds = self._settings(track.shelf_id)
            for index, detection in enumerate(detections):
                overlap = iou(track.bbox, detection.bbox)
                distance = center_distance(track.bbox, detection.bbox)
                if (
                    overlap >= thresholds["tracker_min_iou"]
                    or distance <= thresholds["tracker_match_distance"]
                ):
                    matches.append((distance - overlap, track_id, index))
        used_tracks, used_detections = set(), set()
        assignments = []
        for _, track_id, index in sorted(matches):
            if track_id not in used_tracks and index not in used_detections:
                used_tracks.add(track_id)
                used_detections.add(index)
                assignments.append((self.tracks[track_id], detections[index]))
        for index, detection in enumerate(detections):
            if index not in used_detections:
                self.next_id += 1
                track = Track(self.next_id, detection.bbox, now)
                self.tracks[track.id] = track
                assignments.append((track, detection))
        self.observed_ids = set()
        for track, detection in assignments:
            self.observed_ids.add(track.id)
            track.bbox, track.last_seen = detection.bbox, now
            shelf = self._zone(detection)
            if shelf == track.shelf_id and shelf is not None:
                track.zone_last_seen = now
            elif shelf is not None:
                event = self._end_visit(track, incomplete=False)
                if event:
                    events.append(event)
                track.shelf_id, track.entered, track.zone_last_seen = shelf, now, now
            elif track.shelf_id is not None:
                if now - track.zone_last_seen >= self._settings(track.shelf_id)["exit_grace_seconds"]:
                    event = self._end_visit(track, incomplete=False)
                    if event:
                        events.append(event)
        return events

    def finish(self, incomplete: bool) -> list[dict]:
        events = [
            event
            for track in self.tracks.values()
            if (event := self._end_visit(track, incomplete)) is not None
        ]
        self.tracks.clear()
        self.observed_ids.clear()
        return events

    def visible(self) -> list[dict]:
        return [
            {"id": track.id, "bbox": list(track.bbox)}
            for track in self.tracks.values()
            if track.id in self.observed_ids
        ]

    def active(self) -> list[dict]:
        return [
            {
                "track_id": track.id,
                "shelf_id": track.shelf_id,
                "dwell_seconds": max(0, track.zone_last_seen - track.entered),
            }
            for track in self.tracks.values()
            if track.shelf_id is not None
        ]
