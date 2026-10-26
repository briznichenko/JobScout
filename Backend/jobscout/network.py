import time
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.robotparser import RobotFileParser

from .robots import allowed_by_robots


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Fetcher:
    def __init__(self, config: dict):
        self.config = config
        self.opener = build_opener(NoRedirect())
        self.robots = {}
        self.robot_text = {}
        self.last_request = {}
        self.delays = {}

    def _request(self, url: str) -> bytes:
        host = urlsplit(url).netloc
        for attempt in range(self.config["retries"] + 1):
            delay = max(self.config["delay_seconds"], self.delays.get(host, 0))
            time.sleep(max(0, delay - (time.monotonic() - self.last_request.get(host, 0))))
            self.last_request[host] = time.monotonic()
            try:
                request = Request(url, headers={"User-Agent": self.config["user_agent"], "Accept": "application/rss+xml, application/xml, text/plain"})
                with self.opener.open(request, timeout=self.config["timeout_seconds"]) as response:
                    data = response.read(self.config["max_bytes"] + 1)
                    if len(data) > self.config["max_bytes"]:
                        raise ValueError("Response exceeded configured size limit")
                    return data
            except HTTPError as error:
                if error.code not in {429, 500, 502, 503, 504} or attempt == self.config["retries"]:
                    raise
                retry_after = error.headers.get("Retry-After", "")
                if retry_after and (not retry_after.isdigit() or int(retry_after) > 30):
                    raise ValueError("Server requested a longer retry delay; try a later scan") from error
                time.sleep(max(2 ** attempt, int(retry_after or 0)))
            except (URLError, TimeoutError, HTTPException):
                if attempt == self.config["retries"]:
                    raise
                time.sleep(2 ** attempt)
        raise RuntimeError("Request attempts exhausted")

    def get(self, url: str, allowed_host: str) -> bytes:
        for _ in range(4):
            parts = urlsplit(url)
            if parts.scheme != "https" or parts.netloc != allowed_host:
                raise ValueError("Feed requests must stay on the adapter's HTTPS host")
            if allowed_host not in self.robots:
                parser = RobotFileParser()
                try:
                    raw = self._request(f"https://{allowed_host}/robots.txt")
                    self.robot_text[allowed_host] = raw.decode("utf-8", errors="replace")
                    parser.parse(self.robot_text[allowed_host].splitlines())
                except HTTPError as error:
                    if error.code == 404:
                        parser.parse([])
                        self.robot_text[allowed_host] = ""
                    else:
                        raise ValueError(f"Cannot verify robots.txt (HTTP {error.code}); collection stopped") from error
                self.robots[allowed_host] = parser
                delay = parser.crawl_delay(self.config["user_agent"]) or parser.crawl_delay("*") or 0
                rate = parser.request_rate(self.config["user_agent"]) or parser.request_rate("*")
                self.delays[allowed_host] = max(delay, rate.seconds / rate.requests if rate else 0)
            if not allowed_by_robots(self.robot_text[allowed_host], self.config["user_agent"], url):
                raise ValueError("Collection disallowed by robots.txt")
            try:
                return self._request(url)
            except HTTPError as error:
                if error.code not in {301, 302, 303, 307, 308} or not error.headers.get("Location"):
                    raise
                url = urljoin(url, error.headers["Location"])
        raise ValueError("Too many redirects")
