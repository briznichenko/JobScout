import argparse
import json
import plistlib
import sqlite3
import sys
import uuid
from pathlib import Path

from .config import load_config, migrate_sources
from .model import Vacancy
from .network import Fetcher
from .parsers import parse_feed
from .reporting import write_reports
from .scoring import assess
from .sources import adapter_for
from .local_sources import collect_local, read_source_file
from .tracker import read_tracker
from .storage import STATUSES, Store


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description="Personal RSS job scout. No API keys or AI runtime.")
    cli.add_argument("--config", type=Path, default=Path("config.toml"))
    cli.add_argument("--db", type=Path, help="Default: data/jobs.sqlite beside config")
    cli.add_argument("--reports", type=Path, help="Default: reports/ beside config")
    sub = cli.add_subparsers(dest="command", required=True)
    scan = sub.add_parser("scan", help="Collect enabled public RSS feeds")
    scan.add_argument("--source", help="Only this configured source")
    scan.add_argument("--quiet", action="store_true")
    ingest = sub.add_parser("import", help="Import local JSON alerts or saved RSS")
    ingest.add_argument("file", type=Path)
    ingest.add_argument("--source", help="Override source name for every imported entry")
    ingest.add_argument("--adapter", choices=("dou", "djinni"), help="Required for RSS; omit for JSON")
    ingest.add_argument("--complete-snapshot", action="store_true", help="Assert this file is a complete source inventory; two consecutive absences flag potential removal")
    ingest.add_argument("--quiet", action="store_true")
    tracker = sub.add_parser("import-tracker", help="Import a Google Sheets XLSX/CSV/TSV export, retaining original statuses and notes")
    tracker.add_argument("file", type=Path)
    tracker.add_argument("--sheet-name", default="iOS", help="Tab name for CSV/TSV exports")
    tracker.add_argument("--quiet", action="store_true")
    source_import = sub.add_parser("import-source", help="Import saved source alerts or structured job pages")
    source_import.add_argument("file", type=Path)
    source_import.add_argument("--source", choices=("workua", "robota", "linkedin"), required=True)
    source_import.add_argument("--quiet", action="store_true")
    report = sub.add_parser("report", help="Regenerate latest report with current statuses")
    report.add_argument("--quiet", action="store_true")
    listing = sub.add_parser("list", help="List stored vacancies, including filtered ones")
    listing.add_argument("--status", choices=STATUSES)
    listing.add_argument("--rejected", action="store_true", help="Automatic rejections, independent of application status")
    listing.add_argument("--limit", type=int, default=50)
    show = sub.add_parser("show", help="Inspect all evidence, source records and historical versions")
    show.add_argument("id", type=int)
    status = sub.add_parser("status", help="Change application status; never resets on scans")
    status.add_argument("id", type=int)
    status.add_argument("status", choices=STATUSES)
    sub.add_parser("rescore", help="Re-evaluate stored jobs using current config; creates no new discovery highlights")
    schedule = sub.add_parser("launchd", help="Generate a daily macOS launch agent; does not install it")
    schedule.add_argument("--hour", type=int, default=9)
    schedule.add_argument("--minute", type=int, default=0)
    schedule.add_argument("--output", type=Path, default=Path("com.personal.jobscout.plist"))
    return cli


def emit_report(store, config, directory, quiet):
    path, content = write_reports(store, config, directory)
    print(f"Report: {path.resolve()}" if quiet else content + f"\nSaved: {path.resolve()}")


def main(argv: list[str] | None = None) -> int:
    cli = parser()
    args = cli.parse_args(argv)
    store = None
    try:
        config_path = args.config.resolve()
        migrate_sources(config_path)
        config = load_config(config_path)
        root = config_path.parent
        database = args.db or root / "data/jobs.sqlite"
        reports = args.reports or root / "reports"
        if args.command == "launchd":
            if not 0 <= args.hour <= 23 or not 0 <= args.minute <= 59:
                raise ValueError("Use hour 0–23 and minute 0–59")
            logs = root / "data/logs"
            logs.mkdir(parents=True, exist_ok=True)
            definition = {"Label": "com.personal.jobscout", "ProgramArguments": [sys.executable, "-m", "jobscout", "--config", str(config_path), "--db", str(database.resolve()), "--reports", str(reports.resolve()), "scan", "--quiet"],
                          "WorkingDirectory": str(Path(__file__).resolve().parent.parent), "StartCalendarInterval": {"Hour": args.hour, "Minute": args.minute},
                          "StandardOutPath": str(logs / "stdout.log"), "StandardErrorPath": str(logs / "stderr.log"), "ProcessType": "Background"}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(plistlib.dumps(definition))
            print(f"Generated {args.output.resolve()}; not installed. Schedule uses Mac local time; machine must be awake or wake later.")
            return 0
        store = Store(database)
        if args.command in {"scan", "import", "import-tracker", "import-source"}:
            jobs, failures, tracker_entries = [], [], []
            if args.command == "scan":
                sources = [s for s in config["sources"] if s["enabled"] and (not args.source or s["name"] == args.source)]
                if not sources:
                    raise ValueError("No matching enabled sources")
                fetcher = Fetcher(config["network"])
                archive = root / "data/raw" / uuid.uuid4().hex
                for source in sources:
                    if source["adapter"] in {"tracker", "linkedin", "workua", "robota"}:
                        local, entries = collect_local(source, root)
                        jobs.extend(local.jobs)
                        tracker_entries.extend(entries)
                        failures.extend(local.failures)
                    if source["adapter"] not in {"tracker", "linkedin"}:
                        collection = adapter_for(source["adapter"]).collect(source, fetcher, archive / source["adapter"])
                        jobs.extend(collection.jobs)
                        failures.extend(collection.failures)
            elif args.command == "import-tracker":
                tracker_entries = read_tracker(args.file.read_bytes(), args.file.suffix, sheet_name=args.sheet_name)
            elif args.command == "import-source":
                jobs = read_source_file(args.file, args.source)
            else:
                if args.complete_snapshot and not args.source:
                    raise ValueError("--complete-snapshot requires --source, and must not be used for rolling feeds or alerts")
                raw = args.file.read_bytes()
                if args.adapter:
                    jobs = parse_feed(raw, args.source or args.adapter, args.adapter)
                else:
                    entries = json.loads(raw)
                    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
                        raise ValueError("JSON import must contain an array of vacancy objects")
                    jobs = [Vacancy(**(entry | ({"source": args.source} if args.source else {}))) for entry in entries]
            run_id = store.begin(config)
            for job in jobs:
                store.upsert(job, assess(job, config), run_id)
            for entry in tracker_entries:
                store.import_tracker(entry, assess(entry.vacancy, config), run_id)
            if args.command == "import" and args.complete_snapshot:
                store.complete_snapshot(args.source, {job.url for job in jobs})
            store.finish(run_id, failures)
            emit_report(store, config, reports, args.quiet)
            for failure in failures:
                print(f"Source failure: {failure}", file=sys.stderr)
            return 2 if failures else 0
        if args.command == "report":
            emit_report(store, config, reports, args.quiet)
        elif args.command == "status":
            store.set_status(args.id, args.status)
            print(f"#{args.id}: {args.status}")
        elif args.command == "rescore":
            with store.db:
                for row in store.rows():
                    result = assess(Vacancy(**row["payload"]), config)
                    store.db.execute("UPDATE jobs SET assessment=? WHERE id=?", (json.dumps(result.payload(), ensure_ascii=False), row["id"]))
            print("Stored jobs rescored. Discovery history and application statuses preserved.")
        elif args.command == "list":
            if args.limit < 1:
                raise ValueError("--limit must be positive")
            rows = sorted(store.rows(), key=lambda row: (-row["assessment"]["score"], row["id"]))
            selected = [row for row in rows if (not args.status or row["status"] == args.status) and (not args.rejected or row["assessment"]["decision"] == "rejected")]
            for row in selected[:args.limit]:
                print(f"#{row['id']} {row['assessment']['score']}/100 [{row['status']}; {row['assessment']['decision']}] {row['payload']['title']}")
            print(f"Showing {min(len(selected), args.limit)} of {len(selected)} matching records")
        elif args.command == "show":
            row = next((row for row in store.rows() if row["id"] == args.id), None)
            if not row:
                raise ValueError(f"Unknown vacancy ID {args.id}")
            row["versions"] = [dict(v) for v in store.db.execute("SELECT * FROM versions WHERE job_id=? ORDER BY id", (args.id,))]
            row["source_records"] = [dict(v) for v in store.db.execute("SELECT * FROM listings WHERE job_id=?", (args.id,))]
            row["status_history"] = [dict(v) for v in store.db.execute("SELECT * FROM status_history WHERE job_id=? ORDER BY changed", (args.id,))]
            print(json.dumps(row, indent=2, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        if store:
            store.db.rollback()
        print(f"Error: {error}", file=sys.stderr)
        return 1
    finally:
        if store:
            store.close()
