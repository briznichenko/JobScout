import importlib.util
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser

from .robots import allowed_by_robots


class AccessDenied(ValueError):
    pass


def browser_status():
    interpreter = sys.executable
    if importlib.util.find_spec("playwright") is None:
        return {"ready": False, "message": f'Install browser support with "{interpreter}" -m pip install "playwright>=1.48,<2", then "{interpreter}" -m playwright install chromium'}
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as runtime:
            executable = Path(runtime.chromium.executable_path)
        if not executable.is_file():
            return {"ready": False, "message": f'Chromium is missing. Run "{interpreter}" -m playwright install chromium'}
    except Exception as error:
        return {"ready": False, "message": f"Browser runtime check failed: {error}"}
    return {"ready": True, "message": "Playwright and Chromium are installed for this Python interpreter."}


class BrowserSession:
    def __init__(self, config):
        self.config = config
        self.manager = None
        self.browser = None
        self.contexts = {}
        self.policies = {}
        self.last_request = {}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        try:
            if self.browser:
                self.browser.close()
        finally:
            if self.manager:
                self.manager.stop()

    def _start(self):
        if self.browser:
            return
        try:
            from playwright.sync_api import sync_playwright
        except ImportError as error:
            raise ValueError(browser_status()["message"]) from error
        self.manager = sync_playwright().start()
        try:
            self.browser = self.manager.chromium.launch(channel="chromium", headless=True, timeout=self.config["timeout_seconds"] * 1000)
        except Exception as error:
            raise ValueError(f'Cannot launch Chromium. Run "{sys.executable}" -m playwright install chromium. {error}') from error

    def _context(self, host):
        self._start()
        if host not in self.contexts:
            context = self.browser.new_context(user_agent=self.config["user_agent"], locale="uk-UA", service_workers="block", accept_downloads=False)
            context.set_default_timeout(self.config["timeout_seconds"] * 1000)

            def guard(route):
                request = route.request
                if request.is_navigation_request():
                    parts = urlsplit(request.url)
                    if parts.scheme != "https" or parts.netloc != host:
                        route.abort()
                        return
                    if host in self.policies and not allowed_by_robots(self.policies[host][0], self.config["user_agent"], request.url):
                        route.abort()
                        return
                route.continue_()

            context.route("**/*", guard)
            self.contexts[host] = context
        return self.contexts[host]

    def _pause(self, host, delay):
        time.sleep(max(0, delay - (time.monotonic() - self.last_request.get(host, 0))))
        self.last_request[host] = time.monotonic()

    def _navigate(self, page, url, host, delay):
        self._pause(host, delay)
        response = page.goto(url, wait_until="domcontentloaded")
        if response is None:
            raise ValueError("Navigation returned no HTTP response")
        if response.status in {401, 403, 429}:
            raise AccessDenied(f"HTTP {response.status}; collection stopped, use saved-page import")
        if response.status >= 400:
            raise ValueError(f"HTTP {response.status}")
        return response

    def _policy(self, context, host):
        if host in self.policies:
            return self.policies[host]
        page = context.new_page()
        try:
            self._pause(host, self.config["delay_seconds"])
            response = page.goto(f"https://{host}/robots.txt", wait_until="domcontentloaded")
            if response is None or response.status not in {200, 404}:
                raise AccessDenied(f"Cannot verify robots.txt (HTTP {response.status if response else 'unknown'}); collection stopped")
            raw = "" if response.status == 404 else page.locator("body").inner_text()
            if response.status == 200 and ("<html" in raw.lower() or not any(line.lower().strip().startswith("user-agent:") for line in raw.splitlines())):
                raise AccessDenied("robots.txt is not a readable policy; collection stopped")
            parser = RobotFileParser()
            parser.parse(raw.splitlines())
            delay = parser.crawl_delay(self.config["user_agent"]) or parser.crawl_delay("*") or 0
            rate = parser.request_rate(self.config["user_agent"]) or parser.request_rate("*")
            self.policies[host] = (raw, max(self.config["delay_seconds"], delay, rate.seconds / rate.requests if rate else 0))
            return self.policies[host]
        finally:
            page.close()

    def get(self, url, host, *, detail=False, adapter=""):
        parts = urlsplit(url)
        if parts.scheme != "https" or parts.netloc != host:
            raise ValueError("Browser requests must stay on the adapter's HTTPS host")
        context = self._context(host)
        policy, delay = self._policy(context, host)
        if not allowed_by_robots(policy, self.config["user_agent"], url):
            raise AccessDenied("Collection disallowed by robots.txt")
        page = context.new_page()
        page.on("dialog", lambda dialog: dialog.dismiss())
        verification_failures = []
        page.on("requestfailed", lambda request: verification_failures.append(request.url) if urlsplit(request.url).hostname == "challenges.cloudflare.com" else None)
        try:
            self._navigate(page, url, host, delay)
            selector = "#job-description" if adapter == "workua" else "#description-wrap"
            if not detail:
                selector = "#pjax-jobs-list h2 a" if adapter == "workua" else "alliance-jobseeker-desktop-vacancies-list alliance-vacancy-card-desktop a[href*='vacancy']"
            page.wait_for_function("""({selector, detail}) => {
                const node = document.querySelector(selector);
                if (node && node.textContent.trim()) return true;
                if (detail) return [...document.querySelectorAll('script[type="application/ld+json"]')].some(script => {
                    try { return /JobPosting/.test(script.textContent) && !!JSON.parse(script.textContent); }
                    catch { return false; }
                });
                return /(?:вакансій не знайдено|вакансии не найдены|нічого не знайдено|ничего не найдено|no (?:jobs|results) found|\\b0 ваканс)/i.test(document.body.innerText);
            }""", arg={"selector": selector, "detail": detail})
            raw = page.content().encode("utf-8")
            if len(raw) > self.config["max_bytes"]:
                raise ValueError("Rendered page exceeded configured size limit")
            return raw
        except Exception as error:
            try:
                raw = page.content().encode("utf-8")
                challenge = bool(verification_failures) or page.locator('iframe[src*="challenges.cloudflare.com"], .cf-turnstile, #challenge-running, #challenge-form').count() > 0
                title = page.title()
            except Exception:
                raw, challenge, title = b"", False, ""
            failure = error if isinstance(error, (AccessDenied, ValueError)) else ValueError(f"Browser page did not become readable within the timeout ({title}): {error}")
            if challenge:
                failure = AccessDenied("Site verification is required; automated collection stopped. Import a saved rendered vacancy page instead.")
            if len(raw) <= self.config["max_bytes"]:
                failure.page_html = raw
            if failure is error:
                raise
            raise failure from error
        finally:
            page.close()
