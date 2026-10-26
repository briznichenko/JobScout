import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from jobscout.cli import main
from jobscout.storage import Store
from tests.test_scoring import ROOT


class CLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.database = self.root / "test.sqlite"
        self.reports = self.root / "reports"
        self.base = ["--config", str(ROOT / "config.toml"), "--db", str(self.database), "--reports", str(self.reports)]

    def tearDown(self):
        self.directory.cleanup()

    def run_cli(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = main(self.base + list(args))
        return code, output.getvalue()

    def test_import_status_repeat_report_and_audit(self):
        self.assertEqual(self.run_cli("import", str(ROOT / "examples/alerts.json"), "--quiet")[0], 0)
        self.assertEqual(self.run_cli("status", "1", "Ignored")[0], 0)
        self.assertEqual(self.run_cli("import", str(ROOT / "examples/alerts.json"), "--quiet")[0], 0)
        report = (self.reports / "latest.md").read_text()
        self.assertIn("New: 0", report)
        self.assertIn("Unchanged: 3", report)
        self.assertNotIn("ios-demo", report)
        self.assertIn("relocation", (self.reports / "scan-0002-rejected.md").read_text())
        self.assertEqual(self.run_cli("show", "1")[0], 0)
        self.assertIn("Ignored", self.run_cli("list", "--status", "Ignored")[1])

    def test_invalid_import_is_atomic(self):
        entries = json.loads((ROOT / "examples/alerts.json").read_text())
        entries.append({"source": "bad", "title": "Bad entry"})
        path = self.root / "invalid.json"
        path.write_text(json.dumps(entries))
        self.assertEqual(self.run_cli("import", str(path))[0], 1)
        store = Store(self.database)
        self.assertEqual(store.rows(), [])
        store.close()

    def test_complete_snapshot_requires_named_source(self):
        self.assertEqual(self.run_cli("import", str(ROOT / "examples/alerts.json"), "--complete-snapshot")[0], 1)

    def test_rescore_keeps_discovery_events_and_statuses(self):
        self.run_cli("import", str(ROOT / "examples/alerts.json"), "--quiet")
        self.run_cli("status", "1", "Applied")
        self.assertEqual(self.run_cli("rescore")[0], 0)
        store = Store(self.database)
        self.assertEqual(store.rows()[0]["status"], "Applied")
        self.assertEqual(store.db.execute("SELECT count(*) FROM runs").fetchone()[0], 1)
        store.close()

    def test_unknown_id_is_actionable(self):
        code, message = self.run_cli("status", "123", "Interested")
        self.assertEqual(code, 1)
        self.assertIn("Unknown vacancy ID", message)
