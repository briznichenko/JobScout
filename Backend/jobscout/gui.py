import argparse
import contextlib
import io
import json
import sys
from pathlib import Path

from .cli import main as cli_main
from .config import load_config
from .storage import Store


def snapshot(workspace: Path) -> dict:
    config = load_config(workspace / "config.toml")
    store = Store(workspace / "data/jobs.sqlite")
    try:
        try:
            run = store.latest_run()
        except ValueError:
            run = None
        jobs = store.rows(run["id"] if run else None)
        for row in jobs:
            row["payload"].pop("raw", None)
        last_run = None
        if run:
            counts = dict(store.db.execute("SELECT kind,count(*) FROM events WHERE run_id=? GROUP BY kind", (run["id"],)).fetchall())
            last_run = {"id": run["id"], "started": run["started"], "finished": run["finished"], "failures": json.loads(run["failures"]),
                        "new_count": counts.get("new", 0), "updated_count": counts.get("updated", 0), "unchanged_count": counts.get("unchanged", 0)}
        return {"jobs": jobs, "last_run": last_run, "workspace": str(workspace), "report_path": str(workspace / "reports/latest.md"),
                "minimum_score": config["report"]["minimum_score"], "strong_threshold": config["scoring"]["strong_threshold"]}
    finally:
        store.close()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot")
    sub.add_parser("scan")
    sub.add_parser("rescore")
    sub.add_parser("report")
    status = sub.add_parser("status")
    status.add_argument("id", type=int)
    status.add_argument("status", choices=("New", "Interested", "Applied", "Rejected", "Ignored"))
    ingest = sub.add_parser("import")
    ingest.add_argument("file", type=Path)
    ingest.add_argument("--adapter", choices=("dou", "djinni"))
    args = parser.parse_args(argv)
    try:
        workspace = args.workspace.resolve()
        captured = io.StringIO()
        if args.command != "snapshot":
            command = ["--config", str(workspace / "config.toml")]
            if args.command in {"scan", "report"}:
                command += [args.command, "--quiet"]
            elif args.command == "status":
                command += ["status", str(args.id), args.status]
            elif args.command == "import":
                command += ["import", str(args.file), "--quiet"]
                if args.adapter:
                    command += ["--adapter", args.adapter, "--source", args.adapter]
            else:
                command += [args.command]
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                code = cli_main(command)
            if code not in {0, 2}:
                print(captured.getvalue(), file=sys.stderr)
                return 1
        result = snapshot(workspace)
        result["message"] = captured.getvalue().strip()
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
