import base64
import http.client
import json
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from jobscout.service import HTTPServer, Service, advertise
from tests.test_scoring import ROOT


class HTTPServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.workspace = Path(self.directory.name)
        shutil.copyfile(ROOT / "config.toml", self.workspace / "config.toml")
        self.service = Service(self.workspace)
        self.server = HTTPServer(("127.0.0.1", 0), self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        if self.service.current and self.service.busy():
            self.service.cancel(self.service.current)
            for _ in range(100):
                if not self.service.busy():
                    break
                time.sleep(.02)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, method, path, body=None, token=True):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        headers = {"Authorization": "Bearer " + self.service.token} if token else {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        connection.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        status, payload = response.status, json.loads(response.read())
        connection.close()
        return status, payload

    def test_authentication_required_for_reads_and_writes(self):
        for method, path in [("GET", "/v1/health"), ("GET", "/v1/snapshot"), ("POST", "/v1/scans")]:
            self.assertEqual(self.request(method, path, token=False)[0], 401)
        self.assertEqual((self.workspace / "server-token").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.request("GET", "/v1/health")[0], 200)

    def test_upload_detail_status_and_report_share_database(self):
        content = base64.b64encode((ROOT / "examples/alerts.json").read_bytes()).decode()
        status, result = self.request("POST", "/v1/imports", {"filename": "alerts.json", "content_base64": content, "kind": "vacancies"})
        self.assertEqual(status, 200, result)
        self.assertEqual(len(result["jobs"]), 3)
        self.assertEqual(self.request("GET", "/v1/vacancies/1")[1]["id"], 1)
        status, result = self.request("PATCH", "/v1/vacancies/1/status", {"status": "Applied"})
        self.assertEqual(status, 200, result)
        self.assertEqual(next(job for job in result["jobs"] if job["id"] == 1)["status"], "Applied")
        self.assertEqual(self.request("PATCH", "/v1/vacancies/999/status", {"status": "Applied"})[0], 404)
        self.assertEqual(self.request("POST", "/v1/report")[0], 200)
        self.assertTrue((self.workspace / "reports/latest.md").exists())

    def test_settings_validate_atomically_and_upload_paths_are_rejected(self):
        original = self.request("GET", "/v1/settings")[1]["config"]
        self.assertEqual(self.request("PUT", "/v1/settings", {"config": "invalid = true"})[0], 400)
        self.assertEqual(self.request("GET", "/v1/settings")[1]["config"], original)
        changed = original.replace("minimum_score = 45", "minimum_score = 46")
        self.assertEqual(self.request("PUT", "/v1/settings", {"config": changed})[0], 200)
        self.assertEqual(self.request("GET", "/v1/snapshot")[1]["minimum_score"], 46)
        self.assertEqual(self.request("POST", "/v1/imports", {"filename": "../config.toml", "kind": "vacancies"})[0], 400)
        self.assertEqual(self.request("POST", "/v1/imports", {"filename": "x.json", "kind": "vacancies", "content_base64": "!!!"})[0], 400)

    def test_server_owns_scan_after_disconnect_and_prevents_overlaps(self):
        script = "import signal,time,sys; signal.signal(signal.SIGTERM,lambda *a:sys.exit(130)); print('ready',flush=True); time.sleep(60)"
        import sys
        with patch.object(self.service, "command", return_value=[sys.executable, "-u", "-c", script]):
            status, operation = self.request("POST", "/v1/scans")
            self.assertEqual(status, 202)
            identifier = operation["id"]
            time.sleep(.1)
            self.assertEqual(self.request("GET", "/v1/scans/current")[1]["operation"]["id"], identifier)
            self.assertEqual(self.request("POST", "/v1/scans")[0], 409)
            self.assertEqual(self.request("PUT", "/v1/settings", {"config": "x=1"})[0], 409)
            self.assertEqual(self.request("GET", "/v1/snapshot")[0], 200)
            self.assertEqual(self.request("POST", f"/v1/scans/{identifier}/cancel")[0], 200)
            for _ in range(100):
                operation = self.request("GET", f"/v1/scans/{identifier}")[1]
                if operation["state"] != "running":
                    break
                time.sleep(.02)
            self.assertEqual(operation["state"], "cancelled")
            self.assertIsNotNone(operation["finished"])
        self.assertEqual(self.request("POST", "/v1/rescore")[0], 200)

    def test_restart_marks_interrupted_operation_failed(self):
        operation = {"id": "interrupted", "state": "running", "started": "earlier", "finished": None, "message": None}
        self.service.persist(operation)
        restarted = Service(self.workspace)
        self.assertEqual(restarted.operation("interrupted")["state"], "failed")


class DiscoveryAndLoginTests(unittest.TestCase):
    def test_bonjour_contains_only_public_connection_metadata(self):
        with patch("jobscout.service.shutil.which", return_value="/usr/bin/dns-sd"), patch("jobscout.service.subprocess.Popen") as launch:
            advertise(8765, tls=True)
            arguments = launch.call_args.args[0]
            self.assertEqual(arguments, ["/usr/bin/dns-sd", "-R", "JobScout", "_jobscout._tcp", "local.", "8765", "api=1", "tls=1"])
            self.assertFalse(any("token" in item for item in arguments))

    def test_login_generator_uses_stable_absolute_paths_and_does_not_install(self):
        import contextlib
        import io
        import plistlib
        from jobscout.service_login import main
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "agent.plist"
            with patch("subprocess.run") as run, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["--workspace", str(root / "workspace"), "--host", "0.0.0.0", "--bonjour", "--output", str(output)]), 0)
                run.assert_not_called()
            definition = plistlib.loads(output.read_bytes())
            self.assertTrue(Path(definition["WorkingDirectory"]).is_absolute())
            self.assertIn("--bonjour", definition["ProgramArguments"])
            self.assertTrue(definition["RunAtLoad"])
            self.assertTrue(definition["KeepAlive"])


if __name__ == "__main__":
    unittest.main()
