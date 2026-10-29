import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from jobscout.browser import AccessDenied, BrowserSession
from jobscout.cli import main
from jobscout.config import load_config
from jobscout.lifecycle import scan_lock
from jobscout.scoring import assess
from jobscout.storage import Store
from jobscout.websources import RobotaUAAdapter, WorkUAAdapter, parse_job_page, parse_search
from tests.test_scoring import ROOT


WORK = "https://www.work.ua"
ROBOTA = "https://robota.ua"


def work_search(ids, next_page=""):
    cards = ''.join(f'<div><h2><a href="/jobs/{i}/">iOS Engineer</a></h2></div>' for i in ids)
    return f'<div id="pjax-jobs-list">{cards}</div><ul class="pagination"><li><a href="{next_page}">Next</a></li></ul><aside><a href="/jobs/999/">Recommended</a></aside>'.encode()


def work_detail(title="iOS Engineer"):
    return f'''<script type="application/ld+json">invalid unrelated JSON</script>
    <h1 id="h1-name">{title}</h1><a href="/jobs/by-company/42/"><img alt="Logo"></a>
    <ul><li><span class="glyphicon-company"></span><a href="/jobs/by-company/42/">Example</a></li>
    <li><span class="glyphicon-remote"></span>Дистанційна робота</li>
    <li><span class="glyphicon-hryvnia-fill"></span><span>50 000 грн</span> · Після всіх відрахувань</li>
    <li>Вакансія від 29 жовтня 2026 · Переглядає 1 шукач</li></ul>
    <div id="job-description"><h3>Requirements</h3><ul><li>Swift</li><li>UIKit</li></ul></div>
    <aside>Commercial Android required for a different job</aside>'''.encode()


class FakeFetcher:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def get(self, url, host, **kwargs):
        self.calls.append(url)
        value = self.pages[url]
        if isinstance(value, Exception):
            raise value
        return value


class CrawlerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.store = Store(self.root / "jobs.sqlite")
        self.source = {"name": "workua", "adapter": "workua", "urls": [WORK + "/jobs-ios/"], "transport": "http", "page_limit": 2, "detail_limit": 2, "refresh_hours": 24}

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def collect(self, pages, source=None):
        fetcher = FakeFetcher(pages)
        result = WorkUAAdapter().collect(source or self.source, fetcher, self.root / "raw", cache=self.store)
        return result, fetcher.calls

    def test_dom_fallback_keeps_requirement_boundaries_and_ignores_other_jobs(self):
        job = parse_job_page(work_detail(), "workua", WORK + "/jobs/1/")[0]
        self.assertEqual(job.company, "Example")
        self.assertEqual(job.location, "Дистанційна робота")
        self.assertEqual(job.salary, "50 000 грн · Після всіх відрахувань")
        self.assertEqual(job.description, "Requirements\nSwift\nUIKit")
        self.assertNotIn("Android", job.description)
        self.assertNotIn("Переглядає", job.published)

    def test_saved_rendered_page_requires_original_vacancy_url(self):
        self.assertEqual(parse_job_page(work_detail(), "workua", ""), [])
        data = b'<link rel="canonical" href="https://www.work.ua/jobs/1/">' + work_detail()
        self.assertEqual(parse_job_page(data, "workua", "")[0].url, WORK + "/jobs/1/")
        invalid = b'<link rel="canonical" href="https://other.example/jobs/1/">' + work_detail()
        self.assertEqual(parse_job_page(invalid, "workua", ""), [])

    def test_robota_dom_fallback_uses_scoped_employer_and_description(self):
        data = '''<lib-content><h1 data-id="vacancy-title">iOS Developer</h1>
        <a href="/company42">Example</a><span data-id="vacancy-city">Київ</span>
        <alliance-vac-list-status-label>Віддалена робота</alliance-vac-list-status-label>
        <span data-id="vacancy-salary">50 000 ₴</span><div class="tooltip-inner">29 жовтня 2026</div>
        <div id="description-wrap"><p>Swift</p><p>UIKit</p></div></lib-content>
        <a href="/company999">Other employer</a>'''.encode()
        job = parse_job_page(data, "robota", ROBOTA + "/company42/vacancy1")[0]
        self.assertEqual((job.title, job.company, job.salary), ("iOS Developer", "Example", "50 000 ₴"))
        self.assertEqual(job.description, "Swift\nUIKit")
        self.assertIn("Віддалена", job.location)

    def test_robota_search_excludes_recommendations_and_follows_observed_pagination(self):
        data = b'''<alliance-jobseeker-desktop-vacancies-list>
        <alliance-vacancy-card-desktop><a href="/ru/company42/vacancy1">iOS</a></alliance-vacancy-card-desktop>
        <alliance-recommended-vacancy-list><alliance-vacancy-card-desktop><a href="/company99/vacancy2">Other</a></alliance-vacancy-card-desktop></alliance-recommended-vacancy-list>
        </alliance-jobseeker-desktop-vacancies-list>
        <santa-pagination-with-links><a href="/ru/zapros/ios/ukraine/params;page=2">2</a></santa-pagination-with-links>'''
        links, following = parse_search(data, ROBOTA + "/ru/zapros/ios/ukraine", "robota.ua")
        self.assertEqual(links, [ROBOTA + "/company42/vacancy1"])
        self.assertEqual(following, ROBOTA + "/ru/zapros/ios/ukraine/params;page=2")

    def test_loading_shell_is_failure_but_explicit_empty_search_is_valid(self):
        with self.assertRaisesRegex(ValueError, "No search cards"):
            parse_search(b'<h1>Loading</h1>', WORK + "/jobs-ios/", "www.work.ua")
        self.assertEqual(parse_search('Нічого не знайдено'.encode(), WORK + "/jobs-ios/", "www.work.ua"), ([], None))

    def test_pagination_never_follows_external_or_unrelated_search_links(self):
        data = work_search([1], "https://other.example/jobs-ios/?page=2") + b'<a href="/jobs-other/?page=2">Other</a>'
        self.assertIsNone(parse_search(data, WORK + "/jobs-ios/", "www.work.ua")[1])

    def test_pagination_and_overlap_fetch_details_once_and_report_partial_coverage(self):
        source = self.source | {"urls": [WORK + "/jobs-ios/", WORK + "/jobs-swift/"]}
        pages = {WORK + "/jobs-ios/": work_search([1], "/jobs-ios/?page=2"),
                 WORK + "/jobs-ios/?page=2": work_search([1, 2], "/jobs-ios/?page=3"),
                 WORK + "/jobs-swift/": work_search([2]),
                 WORK + "/jobs/1/": work_detail(), WORK + "/jobs/2/": work_detail()}
        result, calls = self.collect(pages, source)
        self.assertEqual(len(result.jobs), 2)
        self.assertEqual(calls.count(WORK + "/jobs/1/"), 1)
        self.assertNotIn(WORK + "/jobs/999/", calls)
        self.assertTrue(any("page limit" in f for f in result.failures))

    def test_cache_reuses_details_and_preserves_dismissal_without_false_updates(self):
        pages = {WORK + "/jobs-ios/": work_search([1]), WORK + "/jobs/1/": work_detail()}
        config = load_config(ROOT / "config.toml")
        first, _ = self.collect(pages)
        run = self.store.begin(config)
        job_id, _ = self.store.upsert(first.jobs[0], assess(first.jobs[0], config), run)
        self.store.finish(run, [])
        self.store.set_status(job_id, "Ignored")
        second, calls = self.collect({WORK + "/jobs-ios/": work_search([1])})
        self.assertEqual(calls, [WORK + "/jobs-ios/"])
        run = self.store.begin(config)
        self.assertEqual(self.store.upsert(second.jobs[0], assess(second.jobs[0], config), run), (job_id, "unchanged"))
        self.store.finish(run, [])
        self.assertEqual(self.store.rows()[0]["status"], "Ignored")

    def test_budget_advances_to_unfetched_details_next_scan(self):
        self.source["detail_limit"] = 1
        pages = {WORK + "/jobs-ios/": work_search([1, 2]), WORK + "/jobs/1/": work_detail(), WORK + "/jobs/2/": work_detail()}
        first, _ = self.collect(pages)
        second, calls = self.collect(pages)
        self.assertEqual(len(first.jobs), 1)
        self.assertEqual(len(second.jobs), 2)
        self.assertIn(WORK + "/jobs/2/", calls)
        self.assertNotIn(WORK + "/jobs/1/", calls)

    def test_due_refresh_gets_budget_even_with_new_jobs(self):
        self.collect({WORK + "/jobs-ios/": work_search([5]), WORK + "/jobs/5/": work_detail()})
        self.store.db.execute("UPDATE crawl_cache SET fetched='2020-01-01T00:00:00+00:00'")
        self.store.db.commit()
        self.source["detail_limit"] = 1
        result, calls = self.collect({WORK + "/jobs-ios/": work_search([1, 5]), WORK + "/jobs/5/": work_detail("Updated iOS")})
        self.assertEqual(result.jobs[0].title, "Updated iOS")
        self.assertIn(WORK + "/jobs/5/", calls)

    def test_access_denial_stops_host_without_switching_transport(self):
        result, calls = self.collect({WORK + "/jobs-ios/": AccessDenied("HTTP 403")}, self.source | {"urls": [WORK + "/jobs-ios/", WORK + "/jobs-swift/"]})
        self.assertEqual(calls, [WORK + "/jobs-ios/"])
        self.assertEqual(len(result.failures), 1)

    def test_one_bad_detail_preserves_successful_details_and_cache(self):
        result, _ = self.collect({WORK + "/jobs-ios/": work_search([1, 2]), WORK + "/jobs/1/": b'<h1>Incomplete</h1>', WORK + "/jobs/2/": work_detail()})
        self.assertEqual(len(result.jobs), 1)
        self.assertEqual(len(result.failures), 1)
        self.assertIsNotNone(self.store.crawl_entry("workua", "2")["payload"])

    def test_scan_lock_releases_after_exception(self):
        path = self.root / "other.sqlite"
        with self.assertRaisesRegex(ValueError, "already"):
            with scan_lock(path), scan_lock(path):
                pass
        with scan_lock(path):
            pass

    def test_cli_commits_successes_when_one_browser_source_fails(self):
        config_path = self.root / "config.toml"
        config_path.write_bytes((ROOT / "config.toml").read_bytes())
        browser = FakeFetcher({WORK + "/jobs-ios/": work_search([1]), WORK + "/jobs-macos/": OSError("offline"),
                               WORK + "/jobs-technical+support/": work_search([]).replace(b'<div id="pjax-jobs-list"></div>', 'Нічого не знайдено'.encode()),
                               WORK + "/jobs/1/": work_detail()})
        output = io.StringIO()
        with patch("jobscout.cli.BrowserSession") as session, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            session.return_value.__enter__.return_value = browser
            code = main(["--config", str(config_path), "scan", "--source", "workua", "--quiet"])
        self.assertEqual(code, 2)
        with contextlib.closing(Store(self.root / "data/jobs.sqlite")) as store:
            self.assertEqual(len(store.rows()), 1)


@unittest.skipUnless(os.environ.get("JOBSCOUT_BROWSER_TESTS") == "1", "Set JOBSCOUT_BROWSER_TESTS=1 with Playwright and Chromium installed")
class BrowserIntegrationTests(unittest.TestCase):
    def test_robots_denial_prevents_search_navigation(self):
        config = load_config(ROOT / "config.toml")["network"] | {"delay_seconds": 0, "timeout_seconds": 3}
        with BrowserSession(config) as session:
            context = session._context("www.work.ua")
            requested = []
            def respond(route):
                requested.append(route.request.url)
                route.fulfill(status=200, content_type="text/plain", body="User-agent: *\nDisallow: /jobs")
            context.route("**/*", respond)
            with self.assertRaisesRegex(AccessDenied, "disallowed"):
                session.get(WORK + "/jobs-ios/", "www.work.ua", adapter="workua")
            self.assertEqual(requested, [WORK + "/robots.txt"])

    def test_real_browser_renders_delayed_search_and_rejects_cross_host_redirect(self):
        config = load_config(ROOT / "config.toml")["network"] | {"delay_seconds": 0, "timeout_seconds": 3}
        with BrowserSession(config) as session:
            context = session._context("www.work.ua")
            def respond(route):
                if route.request.url.endswith("robots.txt"):
                    route.fulfill(status=200, content_type="text/plain", body="User-agent: *\nAllow: /")
                elif route.request.url.endswith("redirect/"):
                    route.fulfill(status=302, headers={"Location": "https://example.org/blocked"})
                elif "example.org" in route.request.url:
                    route.fallback()
                else:
                    route.fulfill(status=200, content_type="text/html", body='<div id="pjax-jobs-list"></div><script>setTimeout(()=>document.querySelector("#pjax-jobs-list").innerHTML=\'<h2><a href="/jobs/1/">iOS</a></h2>\',100)</script>')
            context.route("**/*", respond)
            raw = session.get(WORK + "/jobs-ios/", "www.work.ua", adapter="workua")
            self.assertEqual(parse_search(raw, WORK + "/jobs-ios/", "www.work.ua")[0], [WORK + "/jobs/1/"])
            with self.assertRaises(ValueError):
                session.get(WORK + "/redirect/", "www.work.ua", adapter="workua")

    def test_sigterm_closes_browser_children_and_releases_scan_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "ready"
            script = '''import sys,time
from pathlib import Path
from jobscout.browser import BrowserSession
from jobscout.config import load_config
from jobscout.lifecycle import cancellation_scope, scan_lock, ScanCancelled
try:
    with scan_lock(Path(sys.argv[1])/'jobs.sqlite'), cancellation_scope(), BrowserSession(load_config(Path('config.toml'))['network']) as browser:
        browser._context('www.work.ua')
        Path(sys.argv[1], 'ready').write_text('ready')
        time.sleep(60)
except ScanCancelled:
    pass
'''
            process = subprocess.Popen([sys.executable, "-c", script, str(root)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 15
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(marker.exists(), "Browser did not start")
                tree = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
                pairs = [tuple(map(int, line.split())) for line in tree.splitlines()]
                children = {process.pid}
                for _ in range(10):
                    children.update(pid for pid, parent in pairs if parent in children)
                children.remove(process.pid)
                self.assertTrue(children)
                process.terminate()
                process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0)
                deadline = time.monotonic() + 5
                alive = set(children)
                while alive and time.monotonic() < deadline:
                    live_pids = set(map(int, subprocess.check_output(["ps", "-axo", "pid="], text=True).split()))
                    alive &= live_pids
                    if alive:
                        time.sleep(0.05)
                self.assertFalse(alive, f"Browser processes survived cancellation: {alive}")
                with scan_lock(root / "jobs.sqlite"):
                    pass
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
