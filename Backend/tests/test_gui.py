import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from jobscout.gui import main, snapshot
from tests.test_scoring import ROOT


class GUIBridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.workspace = Path(self.directory.name)
        shutil.copyfile(ROOT / "config.toml", self.workspace / "config.toml")

    def tearDown(self):
        self.directory.cleanup()

    def run_gui(self, *command):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            code = main(["--workspace", str(self.workspace), *command])
        return code, output.getvalue()

    def test_empty_workspace_snapshot(self):
        result = snapshot(self.workspace)
        self.assertEqual(result["jobs"], [])
        self.assertIsNone(result["last_run"])
        self.assertEqual(result["minimum_score"], 45)

    def test_import_status_and_report_use_single_database(self):
        code, output = self.run_gui("import", str(ROOT / "examples/alerts.json"))
        self.assertEqual(code, 0)
        result = json.loads(output)
        self.assertEqual(len(result["jobs"]), 3)
        self.assertEqual(result["last_run"]["new_count"], 3)
        self.assertNotIn("raw", result["jobs"][0]["payload"])
        code, output = self.run_gui("status", "1", "Interested")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)["jobs"][0]["status"], "Interested")
        code, output = self.run_gui("report")
        self.assertEqual(code, 0)
        self.assertTrue(Path(json.loads(output)["report_path"]).exists())

    def test_invalid_import_returns_failure_not_stale_success(self):
        path = self.workspace / "invalid.json"
        path.write_text('[{"title":"Missing fields"}]')
        code, output = self.run_gui("import", str(path))
        self.assertEqual(code, 1)
        self.assertEqual(output, "")
