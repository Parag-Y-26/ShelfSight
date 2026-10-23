"""Evaluator tests use synthetic intervals only and do not measure model accuracy."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("evaluation", Path(__file__).parents[1] / "scripts" / "evaluate_visits.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class EvaluationTests(unittest.TestCase):
    def test_matching_cannot_count_duplicate_prediction_twice(self):
        visit = {"shelf_id": "test-zone", "start": 0, "end": 10}
        result = evaluation.evaluate([visit, visit], [visit], .5)
        self.assertEqual(result["matched_visits"], 1)
        self.assertEqual(result["precision"], .5)

    def test_wrong_shelf_is_not_a_match(self):
        result = evaluation.evaluate([{"shelf_id": "a", "start": 0, "end": 10}], [{"shelf_id": "b", "start": 0, "end": 10}], .5)
        self.assertEqual(result["recall"], 0)

    def test_empty_dataset_does_not_report_perfect_performance(self):
        result = evaluation.evaluate([], [], .5)
        self.assertIsNone(result["precision"])
        self.assertIsNone(result["recall"])
        self.assertIsNone(result["median_dwell_error_seconds"])

    def test_matching_maximizes_valid_pairs(self):
        predictions = [{"shelf_id": "a", "start": 0, "end": 10}, {"shelf_id": "a", "start": 0, "end": 5}]
        truth = [{"shelf_id": "a", "start": 0, "end": 8}, {"shelf_id": "a", "start": 5, "end": 10}]
        self.assertEqual(evaluation.evaluate(predictions, truth, .5)["matched_visits"], 2)


if __name__ == "__main__":
    unittest.main()
