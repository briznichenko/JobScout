import argparse
import plistlib
import sys
from pathlib import Path


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate a JobScout login LaunchAgent; does not install or load it")
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--cert", type=Path)
    parser.add_argument("--key", type=Path)
    parser.add_argument("--bonjour", action="store_true")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or bool(args.cert) != bool(args.key):
        parser.error("Use port 1–65535 and supply --cert with --key")
    workspace = args.workspace.resolve()
    logs = workspace / "data/logs"
    logs.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-B", "-m", "jobscout.service", "--workspace", str(workspace), "--host", args.host, "--port", str(args.port)]
    if args.bonjour:
        command += ["--bonjour"]
    if args.cert:
        command += ["--cert", str(args.cert.resolve()), "--key", str(args.key.resolve())]
    definition = {"Label": "ua.andrii.JobScout.service", "ProgramArguments": command,
                  "WorkingDirectory": str(Path(__file__).resolve().parents[1]), "RunAtLoad": True,
                  "KeepAlive": True, "ThrottleInterval": 10, "ProcessType": "Background",
                  "StandardOutPath": str(logs / "service.stdout.log"), "StandardErrorPath": str(logs / "service.stderr.log")}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(definition))
    print(f"Generated {args.output.resolve()}; not installed or loaded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
