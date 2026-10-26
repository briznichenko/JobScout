import contextlib
import io
import json
import shutil
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from urllib.error import HTTPError
from zipfile import ZipFile

from jobscout.config import load_config, migrate_sources
from jobscout.gui import main as gui_main, snapshot
from jobscout.local_sources import collect_local, parse_alert, read_source_file
from jobscout.model import canonical_url
from jobscout.scoring import assess
from jobscout.storage import Store
from jobscout.tracker import read_tracker
from jobscout.websources import WorkUAAdapter, parse_job_page
from jobscout.robots import allowed_by_robots
from tests.test_scoring import ROOT, vacancy


CSV = b'Date sent,Company,Role,Channel,Link,Status,Notes,Retrospective\n2026-10-01,Example,Senior iOS Engineer,DOU,https://jobs.dou.ua/companies/example/vacancies/1/#apply,Sent,Commercial Android required is my study note,\n'
PAGE = b'<script type="application/ld+json">{"@type":"JobPosting","title":"iOS Engineer","url":"https://www.work.ua/jobs/123/","description":"<p>Swift UIKit</p>","hiringOrganization":{"name":"Example"},"jobLocationType":"TELECOMMUTE","baseSalary":{"currency":"UAH","value":{"minValue":50000,"maxValue":80000,"unitText":"MONTH"}}}</script>'


def synthetic_xlsx():
    stream = io.BytesIO()
    with ZipFile(stream, "w") as archive:
        archive.writestr("xl/workbook.xml", '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="iOS" sheetId="1" r:id="r1"/></sheets></workbook>')
        archive.writestr("xl/_rels/workbook.xml.rels", '<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/></Relationships>')
        archive.writestr("xl/styles.xml", '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts><font/><font><strike/></font></fonts><cellXfs><xf fontId="0" numFmtId="0"/><xf fontId="1" numFmtId="0"/></cellXfs></styleSheet>')
        archive.writestr("xl/worksheets/sheet1.xml", '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Company</t></is></c><c r="B1" t="inlineStr"><is><t>Role</t></is></c><c r="C1" t="inlineStr"><is><t>Status</t></is></c></row><row r="2"><c r="A2" s="1" t="inlineStr"><is><t>Example</t></is></c><c r="B2" t="inlineStr"><is><t>iOS Engineer</t></is></c><c r="C2" t="inlineStr"><is><t>No response</t></is></c></row></sheetData></worksheet>')
    return stream.getvalue()


class ExpansionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        shutil.copyfile(ROOT / "config.toml", self.root / "config.toml")
        self.config = load_config(self.root / "config.toml")

    def tearDown(self):
        self.directory.cleanup()

    def test_xlsx_retains_strikethrough_without_inventing_rejection(self):
        entry = read_tracker(synthetic_xlsx(), ".xlsx")[0]
        self.assertTrue(entry.metadata["struck_out"])
        self.assertEqual(entry.metadata["original_status"], "No response")
        self.assertEqual(entry.status, "Applied")
        self.assertIn("#range=", entry.vacancy.url)

    def test_missing_role_and_link_are_retained(self):
        entries = read_tracker(b'Company,Role,Status\nExample,,Sent\nAnother,,Rejected\n', ".csv")
        self.assertEqual(len(entries), 2)
        self.assertEqual(len({entry.vacancy.url for entry in entries}), 2)
        self.assertEqual(entries[0].vacancy.title, "Role not recorded in tracker")

    def test_notes_are_not_scored_as_vacancy_requirements(self):
        entry = read_tracker(CSV, ".csv")[0]
        self.assertIn("Android", entry.metadata["fields"]["notes"])
        self.assertNotIn("Android", entry.vacancy.description)
        self.assertFalse(assess(entry.vacancy, self.config).rejected)

    def test_tracker_reuses_live_url_without_replacing_full_description(self):
        entry = read_tracker(CSV, ".csv")[0]
        store = Store(self.root / "data/jobs.sqlite")
        job = vacancy("Swift UIKit, full original description.", url=entry.vacancy.url)
        run = store.begin(self.config)
        store.upsert(job, assess(job, self.config), run)
        store.import_tracker(entry, assess(entry.vacancy, self.config), run)
        store.finish(run, [])
        rows = store.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["payload"]["description"], job.description)
        self.assertEqual(rows[0]["status"], "Applied")
        self.assertEqual(len(rows[0]["tracker_entries"]), 1)
        store.close()

    def test_live_discovery_enriches_previously_imported_tracker_entry(self):
        entry = read_tracker(CSV, ".csv")[0]
        store = Store(self.root / "data/jobs.sqlite")
        run = store.begin(self.config)
        job_id = store.import_tracker(entry, assess(entry.vacancy, self.config), run)
        store.finish(run, [])
        job = vacancy("Full Swift UIKit vacancy requirements.", source="dou", url=entry.vacancy.url)
        run = store.begin(self.config)
        self.assertEqual(store.upsert(job, assess(job, self.config), run), (job_id, "updated"))
        store.finish(run, [])
        self.assertEqual(len(store.rows()), 1)
        self.assertEqual(store.rows()[0]["payload"]["description"], job.description)
        self.assertEqual(store.rows()[0]["status"], "Applied")
        store.close()

    def test_reimport_preserves_local_status_and_updates_source_metadata(self):
        entry = read_tracker(CSV, ".csv")[0]
        store = Store(self.root / "data/jobs.sqlite")
        run = store.begin(self.config)
        job_id = store.import_tracker(entry, assess(entry.vacancy, self.config), run)
        store.finish(run, [])
        store.set_status(job_id, "Ignored")
        changed = replace(entry, status="Rejected", metadata=entry.metadata | {"original_status": "Rejected"})
        for _ in range(2):
            run = store.begin(self.config)
            store.import_tracker(changed, assess(changed.vacancy, self.config), run)
            store.finish(run, [])
        self.assertEqual(store.rows()[0]["status"], "Ignored")
        self.assertEqual(store.rows()[0]["tracker_entries"][0]["original_status"], "Rejected")
        store.close()

    def test_reimport_updates_status_when_local_status_is_untouched(self):
        entry = read_tracker(CSV, ".csv")[0]
        store = Store(self.root / "data/jobs.sqlite")
        for value in (entry, replace(entry, status="Rejected")):
            run = store.begin(self.config)
            store.import_tracker(value, assess(value.vacancy, self.config), run)
            store.finish(run, [])
        self.assertEqual(store.rows()[0]["status"], "Rejected")
        store.close()

    def test_linkedin_tracking_links_canonicalize_to_one_job(self):
        self.assertEqual(canonical_url('https://www.linkedin.com/jobs/view/senior-ios-at-example-12345/?trackingId=abc'), 'https://www.linkedin.com/jobs/view/12345/')

    def test_linkedin_email_does_not_apply_other_jobs_requirements(self):
        mail = b'Subject: Jobs\nContent-Type: text/html; charset=utf-8\n\n<a href="https://www.linkedin.com/jobs/view/123/">Senior iOS Engineer</a><p>Commercial Android required for another job.</p>'
        job = parse_alert(mail, "linkedin")[0]
        self.assertEqual(job.title, "Senior iOS Engineer")
        self.assertNotIn("Android", job.description)
        self.assertFalse(assess(job, self.config).rejected)

    def test_linkedin_scraped_html_is_not_accepted(self):
        path = self.root / "job.html"
        path.write_bytes(PAGE)
        with self.assertRaisesRegex(ValueError, "not scraped HTML"):
            read_source_file(path, "linkedin")

    def test_structured_pages_parse_fields_without_currency_conversion(self):
        job = parse_job_page(PAGE, "workua", "https://www.work.ua/jobs/123/")[0]
        self.assertEqual(job.company, "Example")
        self.assertIn("UAH", job.salary)
        self.assertIn("eligibility unconfirmed", job.location)

    def test_access_denial_is_a_failure_and_no_bypass_is_attempted(self):
        class DeniedFetcher:
            calls = 0
            def get(self, url, host):
                self.calls += 1
                raise HTTPError(url, 403, "Forbidden", {}, None)
        fetcher = DeniedFetcher()
        source = next(s for s in self.config["sources"] if s["name"] == "workua")
        result = WorkUAAdapter().collect(source, fetcher, self.root / "archive")
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(fetcher.calls, 1)
        self.assertEqual(result.jobs, [])

    def test_robots_wildcards_end_markers_and_longest_allow(self):
        policy = 'User-agent: *\nDisallow: /*?sort=\nDisallow: /private/*\nAllow: /private/public$\n'
        self.assertFalse(allowed_by_robots(policy, 'PersonalJobScout/0.1', 'https://example.com/jobs/?sort=new'))
        self.assertFalse(allowed_by_robots(policy, 'PersonalJobScout/0.1', 'https://example.com/private/anything'))
        self.assertTrue(allowed_by_robots(policy, 'PersonalJobScout/0.1', 'https://example.com/private/public'))
        self.assertFalse(allowed_by_robots(policy, 'PersonalJobScout/0.1', 'https://example.com/private/public/other'))

    def test_specific_robots_agent_overrides_wildcard_group(self):
        policy = 'User-agent: *\nDisallow: /\nUser-agent: PersonalJobScout\nAllow: /jobs/\n'
        self.assertTrue(allowed_by_robots(policy, 'PersonalJobScout/0.1', 'https://example.com/jobs/'))

    def test_new_sources_migrate_without_overwriting_profile_or_disabled_source(self):
        config = self.root / "config.toml"
        original = config.read_text().split('[[sources]]\nname = "workua"')[0].replace('commercial_years = 6', 'commercial_years = 7')
        config.write_text(original)
        migrate_sources(config)
        migrate_sources(config)
        value = load_config(config)
        self.assertEqual(value["profile"]["commercial_years"], 7)
        self.assertEqual(len(value["sources"]), 6)
        self.assertTrue(config.with_suffix('.before-sources.toml').exists())

    def test_corrupt_tracker_is_reported_without_breaking_local_collection(self):
        directory = self.root / "imports/google_sheets"
        directory.mkdir(parents=True)
        (directory / "tracker.xlsx").write_bytes(b'not a workbook')
        source = next(s for s in self.config["sources"] if s["name"] == "google_sheets")
        result, entries = collect_local(source, self.root)
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(entries, [])

    def test_gui_tracker_import_copies_private_export_to_inbox(self):
        path = self.root / "incoming.xlsx"
        path.write_bytes(synthetic_xlsx())
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = gui_main(["--workspace", str(self.root), "import-tracker", str(path)])
        self.assertEqual(code, 0)
        self.assertEqual(len(json.loads(output.getvalue())["jobs"]), 1)
        self.assertTrue((self.root / "imports/google_sheets/tracker.xlsx").exists())
        self.assertEqual(len(snapshot(self.root)["sources"]), 6)
