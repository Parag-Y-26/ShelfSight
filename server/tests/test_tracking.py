import pytest

from shelfsight.config import ROOT, BusinessConfig
from shelfsight.providers import Detection
from shelfsight.tracking import ZoneTracker


def tracker(**overrides):
    thresholds = BusinessConfig(ROOT / "config/defaults.json").data["thresholds"]
    thresholds.update(overrides)
    return ZoneTracker(
        [{"shelf_id": "alpha", "x": 0, "y": 0, "width": 0.5, "height": 1}], thresholds, {}
    )


def person(x=0.1, confidence=0.9):
    return Detection((x, 0.1, x + 0.1, 0.6), confidence)


def test_dwell_qualifies_only_after_cutoff_and_stop_last_observed():
    value = tracker(dwell_seconds=2)
    assert value.update([person()], 100) == []
    assert value.update([person()], 101) == []
    assert value.finish(False) == []
    value.update([person()], 110)
    value.update([person()], 111)
    value.update([person()], 112)
    event = value.finish(False)[0]
    assert event["dwell_seconds"] == 2 and event["incomplete"] is False
    assert value.finish(False) == []


def test_tracking_loss_brief_gap_and_reentry_are_distinct():
    value = tracker(dwell_seconds=0.5, tracking_grace_seconds=1)
    value.update([person()], 100)
    value.update([], 100.3)
    value.update([person()], 100.6)
    ended = value.update([], 102)
    assert len(ended) == 1 and ended[0]["incomplete"] is True
    assert ended[0]["dwell_seconds"] == pytest.approx(0.6)
    value.update([person()], 103)
    value.update([person()], 103.6)
    assert value.finish(True)[0]["track_id"] != ended[0]["track_id"]


def test_exit_grace_and_confidence_are_applied():
    value = tracker(dwell_seconds=0.5, exit_grace_seconds=0.1, tracker_match_distance=1)
    value.update([person(confidence=0.2)], 100)
    assert value.active() == []
    value.update([person()], 100.5)
    value.update([person()], 101)
    ended = value.update([person(0.7)], 101.2)
    assert len(ended) == 1 and ended[0]["dwell_seconds"] == 0.5
    assert value.active() == []
