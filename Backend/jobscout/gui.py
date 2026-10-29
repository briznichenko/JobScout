import argparse
import contextlib
import io
import json
import sys
import hashlib
import os
import shutil
from pathlib import Path

from .cli import main as cli_main
from .config import load_config, migrate_sources
from .storage import Store
from .browser import browser_status
from .lifecycle import ScanCancelled, cancellation_scope


def snapshot(workspace: Path) -> dict:
    migrate_sources(workspace / "config.toml")
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
        sources = []
        for source in config["sources"]:
            name = source["name"]
            failures = [f for f in (last_run or {}).get("failures", []) if f.startswith(name + " ")]
            count = sum(any(link["source"] == name for link in row["listings"]) or any(entry.get("platform") == name for entry in row["tracker_entries"]) for row in jobs)
            mode = "Tracker export" if source["adapter"] == "tracker" else "Saved alerts" if source["adapter"] == "linkedin" else f"Public pages ({source['transport']}) + imports" if source["adapter"] in {"workua", "robota"} else "RSS feed"
            sources.append({"id": name, "mode": mode, "enabled": source["enabled"], "count": count, "failures": failures,
                            "search_url": source.get("search_url", "https://jobs.dou.ua/vacancies/" if name == "dou" else "https://djinni.co/jobs/"),
                            "directory": str(workspace / source.get("directory", f"imports/{name}"))})
        return {"jobs": jobs, "sources": sources, "last_run": last_run, "workspace": str(workspace), "report_path": str(workspace / "reports/latest.md"),
                "minimum_score": config["report"]["minimum_score"], "strong_threshold": config["scoring"]["strong_threshold"],
                "browser": browser_status()}
    finally:
        store.close()


def main(argv=None) -> int:
    try:
        with cancellation_scope():
            return run(argv)
    except (ScanCancelled, KeyboardInterrupt):
        print("Search cancelled.", file=sys.stderr)
        return 130


def run(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot")
    sub.add_parser("scan")
    sub.add_parser("rescore")
    sub.add_parser("report")
    tracker = sub.add_parser("import-tracker")
    tracker.add_argument("file", type=Path)
    source_import = sub.add_parser("import-source")
    source_import.add_argument("file", type=Path)
    source_import.add_argument("--source", choices=("workua", "robota", "linkedin"), required=True)
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
            elif args.command == "import-tracker":
                command += ["import-tracker", str(args.file), "--quiet"]
            elif args.command == "import-source":
                command += ["import-source", str(args.file), "--source", args.source, "--quiet"]
            else:
                command += [args.command]
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                code = cli_main(command)
            if code not in {0, 2}:
                print(captured.getvalue(), file=sys.stderr)
                return 1
            if args.command in {"import-tracker", "import-source"}:
                source = "google_sheets" if args.command == "import-tracker" else args.source
                directory = workspace / "imports" / source
                directory.mkdir(parents=True, exist_ok=True)
                filename = "tracker" + args.file.suffix.lower() if source == "google_sheets" else hashlib.sha256(args.file.read_bytes()).hexdigest()[:16] + args.file.suffix.lower()
                destination = directory / filename
                if args.file.resolve() != destination.resolve():
                    temporary = destination.with_suffix(destination.suffix + ".tmp")
                    shutil.copyfile(args.file, temporary)
                    os.replace(temporary, destination)
        result = snapshot(workspace)
        result["message"] = captured.getvalue().strip()
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
