import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

from jobscout.network import Fetcher
from jobscout.parsers import parse_feed, plain_text
from jobscout.sources import DOUAdapter
from tests.test_scoring import ROOT


class SourceTests(unittest.TestCase):
    def test_dou_title_company_salary_description(self):
        job = parse_feed((ROOT / "tests/fixtures/dou.xml").read_bytes(), "dou", "dou")[0]
        self.assertEqual(job.title, "Senior iOS Engineer")
        self.assertEqual(job.company, "Example Studio")
        self.assertEqual(job.salary, "$3000–4000")
        self.assertIn("\n", job.description)
        self.assertNotIn("<p>", job.description)

    def test_djinni_missing_company_remains_unknown(self):
        job = parse_feed((ROOT / "tests/fixtures/djinni.xml").read_bytes(), "djinni", "djinni")[0]
        self.assertEqual(job.company, "")
        self.assertEqual(job.salary, "")

    def test_dou_location_suffix_is_separate_from_company(self):
        data = (ROOT / "tests/fixtures/dou.xml").read_bytes().replace(b"Example Studio, $", "Example Studio, Київ, віддалено, $".encode())
        job = parse_feed(data, "dou", "dou")[0]
        self.assertEqual(job.company, "Example Studio")
        self.assertEqual(job.location, "Київ, віддалено")

    def test_malformed_or_changed_feed_fails_loudly(self):
        for data in (b"<html>Login required</html>", b"<rss><channel>", b"<!DOCTYPE x><rss><channel/></rss>"):
            with self.subTest(data=data):
                with self.assertRaises((ValueError, SyntaxError)):
                    parse_feed(data, "dou", "dou")

    def test_no_invented_empty_description(self):
        with self.assertRaises(ValueError):
            parse_feed(b"<rss><channel><item><title>A</title><link>https://example.com/1</link></item></channel></rss>", "dou", "dou")

    def test_plain_text_preserves_requirement_boundaries(self):
        self.assertEqual(plain_text("<h3>Requirements</h3><ul><li>Swift</li><li>UIKit</li></ul><script>secret</script>"), "Requirements\nSwift\nUIKit")

    def test_one_failed_feed_does_not_discard_successful_feeds(self):
        class FakeFetcher:
            def get(self, url, host):
                if url == "bad":
                    raise OSError("offline")
                return (ROOT / "tests/fixtures/dou.xml").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            result = DOUAdapter().collect({"name": "dou", "urls": ["bad", "good"]}, FakeFetcher(), Path(directory))
            self.assertEqual(len(result.jobs), 1)
            self.assertEqual(len(result.failures), 1)
            self.assertTrue((Path(directory) / "feed-1.xml").exists())

    def test_robots_disallow_stops_feed_request(self):
        fetcher = Fetcher({"user_agent": "PersonalJobScout/0.1"})
        with patch.object(fetcher, "_request", return_value=b"User-agent: *\nDisallow: /jobs") as request:
            with self.assertRaisesRegex(ValueError, "disallowed"):
                fetcher.get("https://djinni.co/jobs/rss/", "djinni.co")
            self.assertEqual(request.call_count, 1)

    def test_unverifiable_robots_fail_closed(self):
        fetcher = Fetcher({"user_agent": "PersonalJobScout/0.1"})
        with patch.object(fetcher, "_request", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                fetcher.get("https://djinni.co/jobs/rss/", "djinni.co")

    def test_redirect_to_another_host_rejected(self):
        fetcher = Fetcher({"user_agent": "PersonalJobScout/0.1"})
        redirect = HTTPError("https://djinni.co/jobs/rss/", 302, "redirect", {"Location": "https://untrusted.example/feed"}, BytesIO())
        with patch.object(fetcher, "_request", side_effect=[b"User-agent: *\nAllow: /", redirect]):
            with self.assertRaisesRegex(ValueError, "HTTPS host"):
                fetcher.get("https://djinni.co/jobs/rss/", "djinni.co")

    def test_timeout_retry_and_rate_limit(self):
        config = {"user_agent": "test", "retries": 1, "delay_seconds": 2, "timeout_seconds": 1, "max_bytes": 1024}
        fetcher = Fetcher(config)
        with patch.object(fetcher.opener, "open", side_effect=TimeoutError), patch("jobscout.network.time.sleep") as sleep:
            with self.assertRaises(TimeoutError):
                fetcher._request("https://djinni.co/jobs/rss/")
            self.assertEqual(fetcher.opener.open.call_count, 2)
            self.assertGreaterEqual(sleep.call_count, 2)
