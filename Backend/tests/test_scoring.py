import json
import unittest
from copy import deepcopy
from pathlib import Path

from jobscout.config import load_config
from jobscout.model import Vacancy
from jobscout.scoring import assess


ROOT = Path(__file__).resolve().parents[1]


def vacancy(description="Remote worldwide. Swift, UIKit, REST API, MVVM, CI/CD. Requirements:\n5+ years of experience.", **fields):
    return Vacancy(**({"source": "test", "url": "https://example.com/jobs/1", "title": "Senior iOS Engineer", "description": description} | fields))


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self.config = load_config(ROOT / "config.toml")

    def test_reference_cases(self):
        cases = json.loads((ROOT / "tests/fixtures/reference.json").read_text())
        for case in cases:
            with self.subTest(case=case["name"]):
                result = assess(vacancy(**case["vacancy"]), self.config)
                self.assertEqual(bool(result.rejected), case["rejected"])

    def test_explainable_bounded_deterministic(self):
        first = assess(vacancy(), self.config)
        self.assertEqual(first, assess(vacancy(), self.config))
        self.assertEqual(first.score, sum(first.components.values()))
        self.assertTrue(0 <= first.score <= 100)

    def test_missing_salary_not_rejected(self):
        result = assess(vacancy(), self.config)
        self.assertFalse(result.rejected)
        self.assertTrue(any("Salary" in u for u in result.uncertainty))

    def test_learning_not_commercial_claim(self):
        result = assess(vacancy("Requirements:\nCombine required.\nSwift actors required."), self.config)
        self.assertEqual(len(result.missing), 2)
        self.assertFalse(result.rejected)

    def test_live_requirement_heading_variations(self):
        result = assess(vacancy("IF YOU ARE\nPrevious practical experience with Kotlin Multiplatform (KMP)."), self.config)
        self.assertTrue(any("Kotlin Multiplatform" in m for m in result.missing))
        self.assertFalse(result.rejected)
        result = assess(vacancy("What we are looking for\nCommercial experience with both Kotlin (Android) and Swift (iOS) in native apps."), self.config)
        self.assertTrue(result.missing)
        self.assertTrue(result.rejected)

    def test_l1_support_title_suffix(self):
        result = assess(vacancy(title="Technical Support Specialist, L1"), self.config)
        self.assertTrue(result.rejected)

    def test_configurable_disabling_filter(self):
        config = deepcopy(self.config)
        config["rules"]["hard"][0]["enabled"] = False
        self.assertFalse(assess(vacancy("Must relocate to Sofia."), config).rejected)

    def test_ukraine_not_assumed_from_remote(self):
        result = assess(vacancy("Remote, Poland residents only. Swift UIKit."), self.config)
        self.assertTrue(any("eligibility" in u for u in result.uncertainty))
        self.assertLess(result.components["location"], 15)

    def test_unknown_requirements_stay_reviewable(self):
        result = assess(vacancy("Details available on request."), self.config)
        self.assertEqual(result.decision, "review")

    def test_commercial_evidence_must_apply_to_unsupported_platform(self):
        result = assess(vacancy("Requirements:\nCommercial iOS experience; collaborate with Android engineers."), self.config)
        self.assertFalse(result.rejected)

    def test_salary_needs_currency_and_period(self):
        result = assess(vacancy(salary="$3,000–4,000"), self.config)
        self.assertEqual(result.components["salary"], 5)
        result = assess(vacancy(salary="$3,000–4,000/month"), self.config)
        self.assertEqual(result.components["salary"], 10)

    def test_support_salary_target_is_independent(self):
        result = assess(vacancy("Remote worldwide. APIs, logs, incident investigation, B2B.", title="L2 Technical Support Engineer", salary="$800–1,000/month"), self.config)
        self.assertEqual(result.role, "support")
        self.assertEqual(result.components["salary"], 10)

    def test_technical_support_not_equated_to_customer_service(self):
        result = assess(vacancy("Investigate logs and REST APIs. B2B asynchronous communication.", title="Application Support Engineer"), self.config)
        self.assertFalse(result.rejected)
        self.assertGreaterEqual(result.components["role"], 20)
