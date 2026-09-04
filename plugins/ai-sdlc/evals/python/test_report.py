"""Unit tests for scripts/metrics/report.py: cost record deduplication and data quality.

    python -B -m unittest discover -s plugins/ai-sdlc/evals/python -v

Standard library only. report.py is loaded from its path, so no package layout is needed and
no __pycache__ is written into the plugin (bytecode writing is switched off before the import).
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT_PY = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "metrics", "report.py"))


def load_report_module():
    spec = importlib.util.spec_from_file_location("sdlc_metrics_report", REPORT_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report = load_report_module()

RUN_1 = {"type": "result", "subtype": "success", "num_turns": 18, "total_cost_usd": 1.42,
         "session_id": "3b1c1f0e-1111-4a0a-9c1e-000000000001", "duration_ms": 184211}
RUN_2 = [
    {"type": "system", "subtype": "init", "session_id": "3b1c1f0e-2222-4a0a-9c1e-000000000002"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Reading."}]}},
    {"type": "result", "subtype": "success", "num_turns": 9, "total_cost_usd": 0.63,
     "session_id": "3b1c1f0e-2222-4a0a-9c1e-000000000002"},
]
RUN_3 = {"run_id": "17765432100", "pr": 240, "total_cost_usd": 2.95, "num_turns": 31,
         "recorded_at": "2026-08-12T15:41:02Z"}


def summary_of(*rows):
    """A cost/report.sh summary covering the given raw records (older rows carry only
    "session" and "file"; newer ones add run_id and session_id)."""
    detail = []
    for row in rows:
        r = row[-1] if isinstance(row, list) else row
        detail.append({
            "file": "x.json", "cost_usd": r["total_cost_usd"], "turns": r.get("num_turns", 0),
            "duration_ms": r.get("duration_ms", 0), "recorded_at": r.get("recorded_at"),
            "pr": r.get("pr"), "session": r.get("session_id") or r.get("run_id"),
        })
    return {"generated_at": "2026-09-01T00:00:00Z", "runs": len(detail),
            "total_cost_usd": round(sum(d["cost_usd"] for d in detail), 6),
            "runs_detail": detail}


EXPORT = {
    "platform": "azure", "repo": "p/r", "since": "2026-08-01", "until": "2026-08-31",
    "prs": [{"id": "1", "created_at": "2026-08-01T09:00:00Z", "merged_at": "2026-08-02T11:00:00Z",
             "first_review_at": "2026-08-01T15:00:00Z", "additions": 10, "deletions": 2,
             "changed_files": 1, "first_commit_at": "2026-07-30T10:00:00Z", "author": "a",
             "is_revert": False}],
    "deployments": [], "incidents": [], "reverts": [],
}


class CostDirCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, name, content):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as fh:
            if isinstance(content, str):
                fh.write(content)
            else:
                json.dump(content, fh)

    def load(self):
        records, warnings = report.load_cost_records(self.dir)
        return records, warnings, report.cost_total(records)


class RawOnly(CostDirCase):
    def test_three_raw_records_sum(self):
        self.write("run-1.json", RUN_1)
        self.write("run-2.json", RUN_2)
        self.write("run-3.json", RUN_3)
        records, warnings, total = self.load()
        self.assertEqual(len(records), 3)
        self.assertEqual(total, 5.0)
        self.assertEqual(warnings, [])
        self.assertEqual({r["key"] for r in records},
                         {RUN_1["session_id"], RUN_2[-1]["session_id"], RUN_3["run_id"]})


class SummaryOnly(CostDirCase):
    def test_details_not_total_plus_details(self):
        self.write("summary.json", summary_of(RUN_1, RUN_2, RUN_3))
        records, warnings, total = self.load()
        self.assertEqual(len(records), 3)
        self.assertEqual(total, 5.0, "total_cost_usd must not be added on top of runs_detail")
        self.assertEqual(warnings, [])

    def test_new_style_rows_with_explicit_ids(self):
        summary = summary_of(RUN_3)
        summary["runs_detail"][0].update({"run_id": "17765432100", "session_id": None})
        self.write("summary.json", summary)
        self.write("run-3.json", RUN_3)
        records, _warnings, total = self.load()
        self.assertEqual(len(records), 1)
        self.assertEqual(total, 2.95)


class Mixed(CostDirCase):
    def test_raw_and_summary_count_once(self):
        self.write("run-1.json", RUN_1)
        self.write("run-2.json", RUN_2)
        self.write("run-3.json", RUN_3)
        self.write("weekly.json", summary_of(RUN_1, RUN_2, RUN_3))
        records, warnings, total = self.load()
        self.assertEqual(len(records), 3)
        self.assertEqual(total, 5.0)
        self.assertTrue(any("more than once" in w for w in warnings), warnings)

    def test_summary_covering_a_subset_adds_only_new_runs(self):
        self.write("run-1.json", RUN_1)
        self.write("weekly.json", summary_of(RUN_1, RUN_3))
        records, _warnings, total = self.load()
        self.assertEqual(len(records), 2)
        self.assertAlmostEqual(total, 1.42 + 2.95, places=6)


class Duplicated(CostDirCase):
    def test_same_raw_record_twice_counts_once(self):
        self.write("a.json", RUN_1)
        self.write("b.json", RUN_1)
        records, warnings, total = self.load()
        self.assertEqual(len(records), 1)
        self.assertEqual(total, 1.42)
        self.assertEqual(len(warnings), 1)
        self.assertIn("counted once", warnings[0])


class Malformed(CostDirCase):
    def test_invalid_json_and_non_numeric_cost_are_warned_not_skipped(self):
        self.write("bad.json", "{not json")
        self.write("text.json", {"run_id": "9", "total_cost_usd": "abc", "num_turns": 3})
        self.write("run-3.json", RUN_3)
        self.write("notes.txt", "ignored: not a .json file")
        records, warnings, total = self.load()
        self.assertEqual(len(records), 1)
        self.assertEqual(total, 2.95)
        self.assertEqual(len(warnings), 2, warnings)
        self.assertTrue(any(w.startswith("bad.json: invalid JSON") for w in warnings), warnings)
        self.assertTrue(any(w.startswith("text.json:") and "non-numeric cost" in w for w in warnings),
                        warnings)

    def test_wrong_shapes_are_warned(self):
        self.write("string.json", '"just a string"')
        self.write("no-result.json", [{"type": "system"}, {"type": "assistant"}])
        self.write("no-cost.json", {"run_id": "1", "num_turns": 2})
        self.write("detail.json", {"runs_detail": {"not": "a list"}})
        records, warnings, total = self.load()
        self.assertEqual(records, [])
        self.assertIsNone(total)
        self.assertEqual(len(warnings), 4, warnings)

    def test_missing_dir_is_not_a_warning(self):
        records, warnings = report.load_cost_records(os.path.join(self.dir, "absent"))
        self.assertEqual((records, warnings), ([], []))
        self.assertIsNone(report.cost_total(records))
        self.assertEqual(report.load_cost_records(None), ([], []))


class CompositeFallback(CostDirCase):
    def test_idless_records_with_different_cost_both_count(self):
        self.write("a.json", {"total_cost_usd": 1.0, "num_turns": 4, "recorded_at": "2026-08-01T00:00:00Z"})
        self.write("b.json", {"total_cost_usd": 2.0, "num_turns": 4, "recorded_at": "2026-08-01T00:00:00Z"})
        records, warnings, total = self.load()
        self.assertEqual(len(records), 2)
        self.assertEqual(total, 3.0)
        self.assertEqual(warnings, [])
        self.assertEqual(records[0]["key"], "1.000000|4|2026-08-01T00:00:00Z|")

    def test_identical_idless_records_count_once(self):
        row = {"total_cost_usd": 1.0, "num_turns": 4, "recorded_at": "2026-08-01T00:00:00Z", "pr": 7}
        self.write("a.json", row)
        self.write("b.json", row)
        records, _warnings, total = self.load()
        self.assertEqual(len(records), 1)
        self.assertEqual(total, 1.0)

    def test_summary_row_matches_idless_raw_record(self):
        raw = {"total_cost_usd": 1.5, "recorded_at": "2026-08-01T00:00:00Z", "pr": "7"}
        self.write("raw.json", raw)
        # report.sh coerces a missing num_turns to 0 and pr stays as it was
        self.write("summary.json", {"runs_detail": [
            {"file": "raw.json", "cost_usd": 1.5, "turns": 0, "recorded_at": "2026-08-01T00:00:00Z",
             "pr": 7, "session": None}]})
        records, _warnings, total = self.load()
        self.assertEqual(len(records), 1)
        self.assertEqual(total, 1.5)


class SourcesNotConfigured(unittest.TestCase):
    def export(self, **extra):
        data = json.loads(json.dumps(EXPORT))
        data.update(extra)
        return data

    def test_deployments_not_configured_renders_source_not_configured(self):
        m = report.compute(self.export(sources={"deployments": "not-configured"}))
        self.assertIsNone(m["dora"]["deployment_frequency_per_week"])
        self.assertIsNone(m["samples"]["deployments"])
        for key in ("deployment_frequency_per_week", "lead_time_h_p50", "change_failure_rate",
                    "defect_escape_rate"):
            self.assertIn(key, m["unavailable"], key)
        text = report.render(m, None)
        self.assertIn("deployments: source not configured", text.splitlines()[2])
        self.assertRegex(text, r"\| Deployment frequency \| source not configured \|")
        self.assertRegex(text, r"\| Lead time for changes \(p50 / p90\) \| source not configured \|")
        self.assertRegex(text, r"\| Change failure rate \| source not configured \|")
        self.assertRegex(text, r"\| Defect escape rate \| source not configured \|")
        self.assertNotRegex(text, r"Deployment frequency \| 0(\.0)? / week")
        self.assertNotRegex(text, r"(^|[^0-9])0 deployments")
        self.assertIn("deployments are not measured (source not configured)", text)
        self.assertIn("## Data quality", text)

    def test_deployments_present_but_source_not_configured_are_ignored_with_a_warning(self):
        deploys = [{"id": "1", "environment": "production", "started_at": "2026-08-03T00:00:00Z",
                    "finished_at": "2026-08-03T00:10:00Z", "status": "success", "sha": "abc"}]
        m = report.compute(self.export(sources={"deployments": "not-configured"}, deployments=deploys))
        self.assertIsNone(m["dora"]["deployment_frequency_per_week"])
        self.assertTrue(any("ignored" in w for w in m["data_quality"]["warnings"]))

    def test_configured_export_without_the_keys_is_unchanged(self):
        m = report.compute(self.export())
        self.assertEqual(m["unavailable"], {})
        self.assertEqual(m["samples"]["deployments"], 0)
        self.assertEqual(m["data_quality"], {"warnings": [], "cost_records": 0, "cost_files": 0})
        text = report.render(m, None)
        self.assertIn("0 deployments (0 successful)", text)
        self.assertRegex(text, r"\| Deployment frequency \| n/a \|")
        self.assertNotIn("## Data quality", text)

    def test_baseline_delta_is_skipped_for_unavailable_metrics(self):
        base = report.compute(self.export())
        m = report.compute(self.export(sources={"deployments": "not-configured"}))
        text = report.render(m, base)
        self.assertNotIn("vs baseline", text.split("## Counterweights")[0])


class ExportWarnings(unittest.TestCase):
    def test_export_warnings_and_partial_sources_are_surfaced(self):
        data = json.loads(json.dumps(EXPORT))
        data["warnings"] = ["reverts: git log covers 12 of 31 days", {"code": "E1"}]
        data["sources"] = {"reverts": "partial"}
        m = report.compute(data, [], ["x.json: invalid JSON (boom)"], 1)
        warnings = m["data_quality"]["warnings"]
        self.assertIn("export: reverts: git log covers 12 of 31 days", warnings)
        self.assertIn('export: {"code": "E1"}', warnings)
        self.assertIn("export: reverts: source status is partial", warnings)
        self.assertIn("cost: x.json: invalid JSON (boom)", warnings)
        self.assertEqual(m["data_quality"]["cost_files"], 1)
        self.assertEqual(m["sources"], {"reverts": "partial"})
        text = report.render(m, None)
        self.assertIn("## Data quality", text)
        self.assertIn("- export: reverts: git log covers 12 of 31 days", text)
        self.assertIn("- cost: x.json: invalid JSON (boom)", text)
        self.assertEqual(m["unavailable"], {}, "partial is a warning, not an unavailable metric")

    def test_cost_total_feeds_cost_per_pr(self):
        records = [{"cost_usd": 1.0, "key": "a"}, {"cost_usd": 2.0, "key": "b"}]
        m = report.compute(json.loads(json.dumps(EXPORT)), records, [], 2)
        self.assertEqual(m["counterweights"]["cost_total_usd"], 3.0)
        self.assertEqual(m["counterweights"]["cost_per_merged_pr_usd"], 3.0)
        self.assertEqual(m["data_quality"]["cost_records"], 2)


if __name__ == "__main__":
    unittest.main()
