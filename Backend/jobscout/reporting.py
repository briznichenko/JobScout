import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def safe(text: str) -> str:
    return re.sub(r"([\\`*_{}\[\]<>#|])", r"\\\1", " ".join(str(text).split()))


def item(row: dict) -> list[str]:
    job, score = row["payload"], row["assessment"]
    lines = [f"### {score['score']}/100 — {safe(job['title'])} · #{row['id']}", "",
             f"- Company: {safe(job['company'] or 'Unknown')} · Status: {row['status']} · Assessment: {score['decision']}",
             f"- Location: {safe(job['location'] or 'Unconfirmed; check full listing')} · Salary: {safe(job['salary'] or 'Not published in feed')}"]
    for label, key in (("Matches", "positive"), ("Concerns", "negative"), ("Missing / unverified", "missing"), ("Review", "uncertainty")):
        if score[key]:
            values = score[key]
            lines.append(f"- {label}: " + "; ".join(safe(value) for value in values[:3]) + (f"; +{len(values) - 3} more (`show {row['id']}`)" if len(values) > 3 else ""))
    for listing in row["listings"]:
        lines.append(f"- [{safe(listing['source'])} original vacancy](<{listing['url']}>) · last seen {listing['last_seen']}" + (" · potentially removed (complete snapshots only)" if listing["potentially_removed"] else ""))
    lines.append("")
    return lines


def render(store, config: dict, run, audit: bool = False) -> str:
    rows = store.rows(run["id"])
    date = datetime.fromisoformat(run["started"]).astimezone(ZoneInfo(config["report"]["timezone"])).strftime("%Y-%m-%d")
    failures = json.loads(run["failures"])
    observed = [row for row in rows if row["kind"] != "previous"]
    rejected = [row for row in observed if row["assessment"]["decision"] == "rejected"]
    if audit:
        lines = [f"# Rejected Vacancy Audit — {date} · scan {run['id']}", "", "Automatic filtering decisions are separate from your application status.", ""]
        for row in rejected:
            lines.extend(item(row))
            lines.extend(f"- Rejection: {safe(reason)}" for reason in row["assessment"]["rejected"])
            lines.append("")
        return "\n".join(lines + (["No automatic rejections in this scan."] if not rejected else [])) + "\n"
    active = [row for row in rows if row["status"] in {"New", "Interested"} and row["assessment"]["decision"] != "rejected"
              and row["assessment"]["score"] >= config["report"]["minimum_score"]
              and not all(link["potentially_removed"] for link in row["listings"])]
    active.sort(key=lambda row: (-row["assessment"]["score"], row["id"]))
    new = [row for row in active if row["kind"] == "new"]
    strong = [row for row in new if row["assessment"]["score"] >= config["scoring"]["strong_threshold"]]
    counts = Counter(row["kind"] for row in observed)
    lines = [f"# Daily Job Report — {date}", "", f"Scan {run['id']} · New strong candidates: **{len(strong)}** (manual checks may remain)", "",
             f"Observed unique vacancies: {len(observed)} · New: {counts['new']} · Updated: {counts['updated']} · Unchanged: {counts['unchanged']}", "",
             "Scores are a rule-based ranking, not a hiring probability. Missing facts remain unknown. Read full listings before applying.", ""]
    budget = config["report"]["limit"]
    for title, selected in (("New opportunities", new), ("Updated opportunities", [row for row in active if row["kind"] == "updated"]),
                            ("Previously discovered — still worth considering", [row for row in active if row["kind"] in {"unchanged", "previous"}])):
        lines.extend([f"## {title} ({len(selected)})", ""])
        for row in selected[:budget]:
            lines.extend(item(row))
        shown = min(budget, len(selected))
        budget -= shown
        if len(selected) > shown:
            lines.extend([f"{len(selected) - shown} more retained in SQLite; use `list` and `show` to inspect.", ""])
        if not selected:
            lines.extend(["None.", ""])
    reasons = Counter(reason.split(":", 1)[0] for row in rejected for reason in row["assessment"]["rejected"])
    lines.extend(["## Filtering audit", "", f"Automatically rejected in this scan: {len(rejected)}. Full evidence is in the companion rejection audit.", ""])
    lines.extend(f"- {safe(reason)}: {count}" for reason, count in sorted(reasons.items()))
    low = sum(row["assessment"]["decision"] != "rejected" and row["assessment"]["score"] < config["report"]["minimum_score"] for row in observed)
    lines.extend([f"- Below report threshold (retained for review): {low}", "", "## Source failures", ""])
    lines.extend([f"- {safe(failure)}" for failure in failures] or ["None."])
    lines.extend(["", "RSS feeds are rolling, incomplete discovery windows. Absence does not mean a vacancy closed. Previous entries may be stale; last-seen timestamps are shown.", ""])
    return "\n".join(lines)


def write_reports(store, config: dict, directory: Path) -> tuple[Path, str]:
    run = store.latest_run()
    directory.mkdir(parents=True, exist_ok=True)
    content = render(store, config, run)
    path = directory / f"scan-{run['id']:04d}.md"
    path.write_text(content, encoding="utf-8")
    (directory / f"scan-{run['id']:04d}-rejected.md").write_text(render(store, config, run, audit=True), encoding="utf-8")
    (directory / "latest.md").write_text(content, encoding="utf-8")
    return path, content
