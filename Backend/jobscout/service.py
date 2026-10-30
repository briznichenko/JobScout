import argparse
import base64
import binascii
import hmac
import fcntl
import json
import os
import secrets
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from .config import load_config, migrate_sources
from .gui import snapshot


class APIError(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def read_token(workspace):
    path = workspace / "server-token"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        os.chmod(path, 0o600)
    else:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(secrets.token_urlsafe(32) + "\n")
    token = path.read_text().strip()
    if len(token) < 32:
        raise ValueError("server-token must contain at least 32 characters")
    return token


class Service:
    def __init__(self, workspace, token=None):
        self.workspace = Path(workspace).resolve()
        self.workspace.mkdir(parents=True, exist_ok=True)
        config = self.workspace / "config.toml"
        if not config.exists():
            config.write_bytes((Path(__file__).resolve().parents[1] / "config.toml").read_bytes())
        migrate_sources(config)
        load_config(config)
        self.token = token or read_token(self.workspace)
        self.lock = threading.RLock()
        self.process = None
        self.operations = {}
        self.current = None
        self.cancel_requested = set()
        self.state_path = self.workspace / "data/server-operation.json"
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        if self.state_path.exists():
            operation = json.loads(self.state_path.read_text())
            if operation["state"] == "running":
                operation.update(state="failed", message="The server restarted before this scan finished. Refresh stored vacancies.", finished=now())
            self.operations[operation["id"]] = operation
            self.current = operation["id"]
            self.persist(operation)

    def persist(self, operation):
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(operation))
        os.replace(temporary, self.state_path)

    def command(self, arguments):
        return [sys.executable, "-B", "-m", "jobscout.gui", "--workspace", str(self.workspace), *arguments]

    def environment(self):
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        return environment

    def busy(self):
        return self.current and self.operations[self.current]["state"] == "running"

    def ensure_idle(self):
        if self.busy():
            raise APIError(409, "A scan is already running. Wait for it to finish or cancel it.")

    def execute(self, arguments):
        result = subprocess.run(self.command(arguments), cwd=Path(__file__).resolve().parents[1], env=self.environment(), capture_output=True)
        if result.returncode:
            raise APIError(422, result.stderr.decode("utf-8", errors="replace").strip()[-4000:] or "The backend could not complete this command.")
        return json.loads(result.stdout)

    def start_scan(self):
        with self.lock:
            self.ensure_idle()
            operation = {"id": uuid.uuid4().hex, "state": "running", "message": "Searching configured sources; results are committed when collection finishes.", "started": now(), "finished": None}
            output = tempfile.TemporaryFile()
            errors = tempfile.TemporaryFile()
            try:
                self.process = subprocess.Popen(self.command(["scan"]), cwd=Path(__file__).resolve().parents[1], env=self.environment(), stdout=output, stderr=errors, start_new_session=True)
            except BaseException:
                output.close()
                errors.close()
                raise
            self.current = operation["id"]
            self.operations[self.current] = operation
            self.persist(operation)
            threading.Thread(target=self.finish_scan, args=(operation["id"], self.process, output, errors), daemon=True).start()
            return dict(operation)

    def finish_scan(self, identifier, process, output, errors):
        code = process.wait()
        errors.seek(0)
        message = errors.read().decode("utf-8", errors="replace").strip()[-4000:]
        output.close()
        errors.close()
        with self.lock:
            cancelled = identifier in self.cancel_requested or code == 130
            state = "cancelled" if cancelled else "completed" if code == 0 else "failed"
            operation = self.operations[identifier]
            operation.update(state=state, message=message or ("Search cancelled. Committed data is retained." if cancelled else "Search complete." if code == 0 else "Search failed."), finished=now())
            self.persist(operation)
            self.process = None
            self.cancel_requested.discard(identifier)
            if len(self.operations) > 100:
                oldest = next(key for key in self.operations if key != self.current)
                del self.operations[oldest]

    def operation(self, identifier):
        with self.lock:
            if identifier not in self.operations:
                raise APIError(404, "Unknown scan operation")
            return dict(self.operations[identifier])

    def cancel(self, identifier):
        with self.lock:
            operation = self.operation(identifier)
            if operation["state"] == "running" and self.process:
                self.cancel_requested.add(identifier)
                self.process.terminate()
                self.operations[identifier]["message"] = "Cancellation requested; waiting for the crawler to stop."
                self.persist(self.operations[identifier])
            return self.operation(identifier)

    def dispatch(self, method, path, body):
        parts = path.strip("/").split("/")
        if parts[:1] != ["v1"]:
            raise APIError(404, "Unknown API route")
        route = parts[1:]
        if method == "GET":
            if route == ["health"]:
                return 200, {"status": "ok", "api_version": 1}
            if route in (["snapshot"], ["vacancies"]):
                with self.lock:
                    return 200, snapshot(self.workspace)
            if len(route) == 2 and route[0] == "vacancies":
                with self.lock:
                    vacancy = next((job for job in snapshot(self.workspace)["jobs"] if str(job["id"]) == route[1]), None)
                if vacancy is None:
                    raise APIError(404, "Unknown vacancy")
                return 200, vacancy
            if route == ["scans", "current"]:
                return 200, {"operation": self.operation(self.current) if self.current else None}
            if len(route) == 2 and route[0] == "scans":
                return 200, self.operation(route[1])
            if route == ["settings"]:
                with self.lock:
                    return 200, {"config": (self.workspace / "config.toml").read_text()}
        if method == "POST" and route == ["scans"]:
            return 202, self.start_scan()
        if method == "POST" and len(route) == 3 and route[0] == "scans" and route[2] == "cancel":
            return 200, self.cancel(route[1])
        with self.lock:
            self.ensure_idle()
            if method == "PATCH" and len(route) == 3 and route[0] == "vacancies" and route[2] == "status":
                if body.get("status") not in {"New", "Interested", "Applied", "Rejected", "Ignored"} or not route[1].isdigit():
                    raise APIError(400, "Invalid vacancy ID or status")
                if not any(str(job["id"]) == route[1] for job in snapshot(self.workspace)["jobs"]):
                    raise APIError(404, "Unknown vacancy")
                return 200, self.execute(["status", route[1], body["status"]])
            if method == "POST" and route in (["rescore"], ["report"]):
                return 200, self.execute(route)
            if method == "POST" and route == ["imports"]:
                return 200, self.import_file(body)
            if method == "PUT" and route == ["settings"]:
                config = body.get("config")
                if not isinstance(config, str):
                    raise APIError(400, "config must be a TOML string")
                with tempfile.NamedTemporaryFile(dir=self.workspace, suffix=".toml", delete=False) as stream:
                    temporary = Path(stream.name)
                    stream.write(config.encode())
                try:
                    load_config(temporary)
                    os.replace(temporary, self.workspace / "config.toml")
                finally:
                    temporary.unlink(missing_ok=True)
                return 200, {"config": config}
        raise APIError(404, "Unknown API route")

    def import_file(self, body):
        filename = body.get("filename", "")
        if not isinstance(filename, str) or not filename or Path(filename).name != filename or "\\" in filename:
            raise APIError(400, "Provide a filename without directory components")
        try:
            data = base64.b64decode(body.get("content_base64", ""), validate=True)
        except (ValueError, TypeError, binascii.Error) as error:
            raise APIError(400, "Invalid base64 upload") from error
        kind = body.get("kind")
        with tempfile.TemporaryDirectory(prefix="jobscout-upload-") as directory:
            path = Path(directory) / filename
            path.write_bytes(data)
            if kind == "tracker":
                command = ["import-tracker", str(path)]
            elif kind == "source" and body.get("source") in {"linkedin", "workua", "robota"}:
                command = ["import-source", str(path), "--source", body["source"]]
            elif kind == "vacancies":
                command = ["import", str(path)]
                if body.get("adapter") is not None:
                    if body["adapter"] not in {"dou", "djinni"}:
                        raise APIError(400, "Invalid import adapter")
                    command += ["--adapter", body["adapter"]]
            else:
                raise APIError(400, "Invalid import kind or source")
            return self.execute(command)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def respond(self, status, result):
        data = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_request(self):
        self.connection.settimeout(30)
        service = self.server.service
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + service.token):
            self.respond(401, {"error": "Authentication required. Enter the server token in connection settings."})
            return
        try:
            if self.headers.get("Transfer-Encoding"):
                raise APIError(400, "Chunked uploads are not supported")
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 16 * 1024 * 1024:
                raise APIError(413, "Request exceeds the 16 MiB limit")
            body = json.loads(self.rfile.read(length)) if length else {}
            if not isinstance(body, dict):
                raise APIError(400, "Expected a JSON object")
            status, result = service.dispatch(self.command, urlsplit(self.path).path, body)
            self.respond(status, result)
        except APIError as error:
            self.respond(error.status, {"error": str(error)})
        except (ValueError, KeyError, TypeError, OSError) as error:
            self.respond(400, {"error": str(error)})
        except Exception:
            self.respond(500, {"error": "The server could not complete this request. Check server logs."})

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request
    do_PUT = handle_request


class HTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, service):
        self.service = service
        super().__init__(address, Handler)


def advertise(port, tls=False, name="JobScout"):
    executable = shutil.which("dns-sd")
    if not executable:
        raise ValueError("Bonjour publishing requires the macOS dns-sd command")
    return subprocess.Popen([executable, "-R", name, "_jobscout._tcp", "local.", str(port), "api=1", "tls=" + ("1" if tls else "0")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(argv=None):
    parser = argparse.ArgumentParser(description="JobScout authenticated HTTP service")
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--cert", type=Path)
    parser.add_argument("--key", type=Path)
    parser.add_argument("--bonjour", action="store_true", help="Advertise a LAN service through macOS Bonjour")
    args = parser.parse_args(argv)
    if bool(args.cert) != bool(args.key):
        parser.error("--cert and --key must be supplied together")
    if args.bonjour and args.host in {"127.0.0.1", "localhost", "::1"}:
        parser.error("Bonjour requires a LAN binding such as --host 0.0.0.0")
    args.workspace.mkdir(parents=True, exist_ok=True)
    lock_stream = (args.workspace / "server.lock").open("a")
    try:
        fcntl.flock(lock_stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("Another JobScout service already owns this workspace")
    service = Service(args.workspace)
    server = HTTPServer((args.host, args.port), service)
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    publication = advertise(server.server_port, tls=bool(args.cert)) if args.bonjour else None

    def stop(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, stop)
    print(f"JobScout listening on {args.host}:{args.port}. Token file: {service.workspace / 'server-token'}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if publication:
            publication.terminate()
            publication.wait(timeout=5)
        if service.current and service.busy():
            service.cancel(service.current)
            if service.process:
                try:
                    service.process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    service.process.kill()
        lock_stream.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
