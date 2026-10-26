import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from jobscout.model import Assessment
from jobscout.storage import Store
from tests.test_scoring import vacancy


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.directory.name) / "test.sqlite")
        self.score = Assessment(80, "review", "apple")

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def save(self, jobs):
        run = self.store.begin({})
        results = [self.store.upsert(job, self.score, run) for job in jobs]
        self.store.finish(run, [])
        return results

    def test_repeat_whitespace_tracking_and_publication_not_new(self):
        job = vacancy()
        self.assertEqual(self.save([job]), [(1, "new")])
        other = replace(job, description=job.description + "  ", published="tomorrow", url=job.url + "?utm_source=rss")
        self.assertEqual(self.save([other]), [(1, "unchanged")])
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM versions").fetchone()[0], 1)

    def test_meaningful_change_history_and_status_preserved(self):
        job = vacancy()
        self.save([job])
        self.store.set_status(1, "Ignored")
        self.assertEqual(self.save([replace(job, description=job.description + "\nNew mandatory condition.")]), [(1, "updated")])
        self.assertEqual(self.store.rows()[0]["status"], "Ignored")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM versions").fetchone()[0], 2)

    def test_cross_source_duplicates_preserve_links_and_dismissal(self):
        job = vacancy("Swift UIKit " * 40)
        self.save([job])
        self.store.set_status(1, "Applied")
        duplicate = replace(job, source="other", url="https://other.example/job/2")
        self.assertEqual(self.save([duplicate]), [(1, "unchanged")])
        self.assertEqual(len(self.store.rows()), 1)
        self.assertEqual(len(self.store.rows()[0]["listings"]), 2)
        self.assertEqual(self.store.rows()[0]["status"], "Applied")

    def test_different_known_companies_never_merged(self):
        job = vacancy("Swift UIKit " * 40, company="A")
        self.save([job])
        self.save([replace(job, company="B", source="other", url="https://other.example/job/2")])
        self.assertEqual(len(self.store.rows()), 2)

    def test_title_alone_not_a_duplicate(self):
        self.save([vacancy("Develop one application.", company="A")])
        self.save([vacancy("Build a separate app.", company="A", source="other", url="https://other.example/jobs/2")])
        self.assertEqual(len(self.store.rows()), 2)

    def test_feeds_do_not_infer_removal(self):
        self.save([vacancy()])
        self.save([])
        self.save([])
        self.assertEqual(self.store.rows()[0]["listings"][0]["potentially_removed"], 0)

    def test_only_complete_snapshots_flag_potential_removal(self):
        self.save([vacancy()])
        with self.store.db:
            self.store.complete_snapshot("test", set())
        self.assertEqual(self.store.rows()[0]["listings"][0]["potentially_removed"], 0)
        with self.store.db:
            self.store.complete_snapshot("test", set())
        self.assertEqual(self.store.rows()[0]["listings"][0]["potentially_removed"], 1)
        self.assertEqual(self.save([vacancy()]), [(1, "updated")])
        self.assertEqual(self.store.rows()[0]["listings"][0]["potentially_removed"], 0)

    def test_multi_feed_single_job_new_event_preserved(self):
        self.save([vacancy(), vacancy()])
        self.assertEqual(self.store.db.execute("SELECT kind FROM events").fetchone()[0], "new")

    def test_original_url_retained(self):
        self.save([vacancy(url="https://example.com/jobs/1?utm_source=alerts")])
        self.assertIn("utm_source=alerts", self.store.rows()[0]["payload"]["original_url"])

    def test_rollback_does_not_publish_partial_run(self):
        run = self.store.begin({})
        self.store.upsert(vacancy(), self.score, run)
        self.store.db.rollback()
        self.assertEqual(self.store.rows(), [])
