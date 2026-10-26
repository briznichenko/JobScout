import json
import sqlite3
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

from .model import Assessment, Vacancy, normalized


STATUSES = ("New", "Interested", "Applied", "Rejected", "Ignored")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=15)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY, started TEXT NOT NULL, finished TEXT,
                failures TEXT NOT NULL DEFAULT '[]', config TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS jobs (
                id INTEGER PRIMARY KEY, status TEXT NOT NULL DEFAULT 'New'
                    CHECK(status IN ('New','Interested','Applied','Rejected','Ignored')),
                created TEXT NOT NULL, updated TEXT NOT NULL, payload TEXT NOT NULL,
                assessment TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS listings (
                source TEXT NOT NULL, url TEXT NOT NULL, job_id INTEGER NOT NULL REFERENCES jobs(id),
                first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, fingerprint TEXT NOT NULL,
                payload TEXT NOT NULL, missing_count INTEGER NOT NULL DEFAULT 0,
                potentially_removed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(source, url)
            );
            CREATE TABLE IF NOT EXISTS versions (
                id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id),
                run_id INTEGER NOT NULL REFERENCES runs(id), source TEXT NOT NULL,
                url TEXT NOT NULL, captured TEXT NOT NULL, payload TEXT NOT NULL,
                assessment TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                run_id INTEGER NOT NULL REFERENCES runs(id), job_id INTEGER NOT NULL REFERENCES jobs(id),
                kind TEXT NOT NULL, PRIMARY KEY(run_id,job_id)
            );
            CREATE TABLE IF NOT EXISTS status_history (
                job_id INTEGER NOT NULL REFERENCES jobs(id), changed TEXT NOT NULL,
                old_status TEXT NOT NULL, new_status TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS listings_job ON listings(job_id);
            CREATE TABLE IF NOT EXISTS tracker_entries (
                entry_key TEXT PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id),
                payload TEXT NOT NULL, mapped_status TEXT, imported TEXT NOT NULL,
                local_history_count INTEGER NOT NULL DEFAULT 0
            );
        """)

    def close(self):
        self.db.close()

    def begin(self, config: dict) -> int:
        self.db.execute("BEGIN IMMEDIATE")
        cursor = self.db.execute("INSERT INTO runs(started, config) VALUES (?,?)", (now(), json.dumps(config, ensure_ascii=False)))
        return cursor.lastrowid

    def _duplicate(self, job: Vacancy) -> int | None:
        same_url = self.db.execute("SELECT job_id FROM listings WHERE url=? LIMIT 1", (job.url,)).fetchone()
        if same_url:
            return same_url[0]
        for row in self.db.execute("SELECT job_id, payload FROM listings WHERE source != ?", (job.source,)):
            existing = Vacancy(**json.loads(row["payload"]))
            if normalized(existing.title) != normalized(job.title):
                continue
            if existing.company and job.company and normalized(existing.company) != normalized(job.company):
                continue
            left, right = normalized(existing.description), normalized(job.description)
            if len(left) < 150 or len(right) < 150:
                continue
            same_description = left == right
            same_employer = bool(existing.company and job.company and normalized(existing.company) == normalized(job.company))
            similar = same_employer and normalized(existing.location) == normalized(job.location) and SequenceMatcher(None, left, right, autojunk=False).ratio() >= 0.97
            if same_description or similar:
                return row["job_id"]
        return None

    def upsert(self, job: Vacancy, assessment: Assessment, run_id: int) -> tuple[int, str]:
        timestamp = now()
        payload, scored = json.dumps(job.payload(), ensure_ascii=False), json.dumps(assessment.payload(), ensure_ascii=False)
        existing = self.db.execute("SELECT * FROM listings WHERE source=? AND url=?", (job.source, job.url)).fetchone()
        if existing:
            job_id = existing["job_id"]
            kind = "updated" if existing["fingerprint"] != job.fingerprint() else "unchanged"
            if existing["potentially_removed"]:
                kind = "updated"
            self.db.execute("UPDATE listings SET last_seen=?,fingerprint=?,payload=?,missing_count=0,potentially_removed=0 WHERE source=? AND url=?",
                            (timestamp, job.fingerprint(), payload, job.source, job.url))
        else:
            job_id = self._duplicate(job)
            kind = "unchanged" if job_id else "new"
            if not job_id:
                cursor = self.db.execute("INSERT INTO jobs(created,updated,payload,assessment) VALUES (?,?,?,?)", (timestamp, timestamp, payload, scored))
                job_id = cursor.lastrowid
            self.db.execute("INSERT INTO listings(source,url,job_id,first_seen,last_seen,fingerprint,payload) VALUES (?,?,?,?,?,?,?)",
                            (job.source, job.url, job_id, timestamp, timestamp, job.fingerprint(), payload))
        representative = json.loads(self.db.execute("SELECT payload FROM jobs WHERE id=?", (job_id,)).fetchone()[0])
        if job.source != "google_sheets" and representative["source"] == "google_sheets":
            kind = "updated"
        if kind != "unchanged":
            self.db.execute("UPDATE jobs SET updated=?,payload=?,assessment=? WHERE id=?", (timestamp, payload, scored, job_id))
        elif existing and self.db.execute("SELECT payload FROM jobs WHERE id=?", (job_id,)).fetchone()[0] == existing["payload"]:
            self.db.execute("UPDATE jobs SET assessment=? WHERE id=?", (scored, job_id))
        if kind != "unchanged" or not existing:
            self.db.execute("INSERT INTO versions(job_id,run_id,source,url,captured,payload,assessment) VALUES (?,?,?,?,?,?,?)", (job_id, run_id, job.source, job.url, timestamp, payload, scored))
        prior = self.db.execute("SELECT kind FROM events WHERE run_id=? AND job_id=?", (run_id, job_id)).fetchone()
        rank = {"unchanged": 0, "updated": 1, "new": 2}
        if not prior or rank[kind] > rank[prior[0]]:
            self.db.execute("INSERT OR REPLACE INTO events(run_id,job_id,kind) VALUES (?,?,?)", (run_id, job_id, kind))
        return job_id, kind

    def import_tracker(self, entry, assessment: Assessment, run_id: int) -> int:
        previous = self.db.execute("SELECT * FROM tracker_entries WHERE entry_key=?", (entry.key,)).fetchone()
        if previous:
            job_id = previous["job_id"]
            self.db.execute("INSERT OR IGNORE INTO events(run_id,job_id,kind) VALUES (?,?,?)", (run_id, job_id, "unchanged"))
            self.db.execute("UPDATE listings SET last_seen=? WHERE source='google_sheets' AND job_id=?", (now(), job_id))
        else:
            job_id, _ = self.upsert(entry.vacancy, assessment, run_id)
        row = self.db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
        history_count = self.db.execute("SELECT count(*) FROM status_history WHERE job_id=?", (job_id,)).fetchone()[0]
        unchanged_locally = previous and history_count == previous["local_history_count"] and row[0] == previous["mapped_status"]
        if entry.status and (not previous and row[0] == "New" and history_count == 0 or unchanged_locally):
            self.db.execute("UPDATE jobs SET status=? WHERE id=?", (entry.status, job_id))
        self.db.execute("INSERT OR REPLACE INTO tracker_entries(entry_key,job_id,payload,mapped_status,imported,local_history_count) VALUES (?,?,?,?,?,?)",
                        (entry.key, job_id, json.dumps(entry.metadata, ensure_ascii=False), entry.status, now(), previous["local_history_count"] if previous and not unchanged_locally else history_count))
        return job_id

    def complete_snapshot(self, source: str, seen_urls: set[str]):
        for row in self.db.execute("SELECT url,missing_count FROM listings WHERE source=?", (source,)).fetchall():
            if row["url"] not in seen_urls:
                count = row["missing_count"] + 1
                self.db.execute("UPDATE listings SET missing_count=?,potentially_removed=? WHERE source=? AND url=?", (count, count >= 2, source, row["url"]))

    def finish(self, run_id: int, failures: list[str]):
        self.db.execute("UPDATE runs SET finished=?,failures=? WHERE id=?", (now(), json.dumps(failures), run_id))
        self.db.commit()

    def set_status(self, job_id: int, status: str):
        row = self.db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise ValueError(f"Unknown vacancy ID {job_id}")
        self.db.execute("UPDATE jobs SET status=? WHERE id=?", (status, job_id))
        self.db.execute("INSERT INTO status_history VALUES (?,?,?,?)", (job_id, now(), row[0], status))
        self.db.commit()

    def latest_run(self) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM runs WHERE finished IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
        if not row:
            raise ValueError("No completed scans. Run scan or import first.")
        return row

    def rows(self, run_id: int | None = None) -> list[dict]:
        query = "SELECT jobs.*, COALESCE(events.kind,'previous') AS kind FROM jobs LEFT JOIN events ON jobs.id=events.job_id AND events.run_id=? ORDER BY jobs.id"
        result = []
        for row in self.db.execute(query, (run_id,)):
            value = dict(row)
            value["payload"] = json.loads(value["payload"])
            value["assessment"] = json.loads(value["assessment"])
            value["tracker_entries"] = [json.loads(item[0]) for item in self.db.execute("SELECT payload FROM tracker_entries WHERE job_id=?", (row["id"],))]
            value["listings"] = [dict(item) for item in self.db.execute("SELECT source,url,last_seen,potentially_removed FROM listings WHERE job_id=?", (row["id"],))]
            result.append(value)
        return result
