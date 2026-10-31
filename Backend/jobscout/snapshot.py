import json
from pathlib import Path

from .browser import browser_status
from .config import load_config, migrate_sources
from .storage import Store


def source_mode(source: dict) -> str:
    match source["adapter"]:
        case "tracker":
            return "Tracker export"
        case "linkedin":
            return "Saved alerts"
        case "workua" | "robota":
            return f"Public pages ({source['transport']}) + imports"
        case _:
            return "RSS feed"


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
            counts = dict(store.db.execute(
                "SELECT kind,count(*) FROM events WHERE run_id=? GROUP BY kind", (run["id"],)
            ).fetchall())
            last_run = {
                "id": run["id"],
                "started": run["started"],
                "finished": run["finished"],
                "failures": json.loads(run["failures"]),
                "new_count": counts.get("new", 0),
                "updated_count": counts.get("updated", 0),
                "unchanged_count": counts.get("unchanged", 0),
            }
        sources = []
        for source in config["sources"]:
            name = source["name"]
            failures = [failure for failure in (last_run or {}).get("failures", []) if failure.startswith(name + " ")]
            count = sum(
                any(link["source"] == name for link in row["listings"])
                or any(entry.get("platform") == name for entry in row["tracker_entries"])
                for row in jobs
            )
            default_search = "https://jobs.dou.ua/vacancies/" if name == "dou" else "https://djinni.co/jobs/"
            sources.append({
                "id": name,
                "mode": source_mode(source),
                "enabled": source["enabled"],
                "count": count,
                "failures": failures,
                "search_url": source.get("search_url", default_search),
                "directory": str(workspace / source.get("directory", f"imports/{name}")),
            })
        return {
            "jobs": jobs,
            "sources": sources,
            "last_run": last_run,
            "workspace": str(workspace),
            "report_path": str(workspace / "reports/latest.md"),
            "minimum_score": config["report"]["minimum_score"],
            "strong_threshold": config["scoring"]["strong_threshold"],
            "browser": browser_status(),
        }
    finally:
        store.close()
