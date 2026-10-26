import json
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit

from .model import Vacancy
from .parsers import plain_text
from .sources import Collection


class PageData(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.json_blocks = []
        self.links = []
        self.current = None
        self.anchor = None
        self.anchors = []
        self.canonical = ""

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href", "")
        if tag == "meta" and attrs.get("property") == "og:url" and not self.canonical:
            self.canonical = attrs.get("content", "")
        if tag == "script" and attrs.get("type", "").split(";", 1)[0].strip() == "application/ld+json":
            self.current = []
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
            self.anchor = (attrs["href"], [])

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)
        if self.anchor is not None:
            self.anchor[1].append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.anchor is not None:
            self.anchors.append((self.anchor[0], " ".join("".join(self.anchor[1]).split())))
            self.anchor = None
        if tag == "script" and self.current is not None:
            self.json_blocks.append("".join(self.current))
            self.current = None


def _objects(value):
    if isinstance(value, list):
        for item in value:
            yield from _objects(item)
    elif isinstance(value, dict):
        yield value
        for item in value.values():
            if isinstance(item, (dict, list)):
                yield from _objects(item)


def parse_job_page(data: bytes, source: str, url: str) -> list[Vacancy]:
    parser = PageData()
    parser.feed(data.decode("utf-8", errors="replace"))
    jobs = []
    for block in parser.json_blocks:
        for value in _objects(json.loads(block)):
            types = value.get("@type", [])
            if "JobPosting" not in (types if isinstance(types, list) else [types]):
                continue
            organization = value.get("hiringOrganization") or {}
            if isinstance(organization, list):
                organization = organization[0] if organization else {}
            company = organization.get("name", "")
            locations = value.get("jobLocation") or []
            if isinstance(locations, dict):
                locations = [locations]
            place = []
            if value.get("jobLocationType") == "TELECOMMUTE":
                place.append("Remote; country eligibility unconfirmed")
            for location in locations:
                address = location.get("address") or {}
                if isinstance(address, str):
                    place.append(address)
                else:
                    place.extend(str(address[k]) for k in ("addressLocality", "addressRegion", "addressCountry") if address.get(k) and not isinstance(address[k], dict))
            salary = value.get("baseSalary") or {}
            salary_text = ""
            if isinstance(salary, dict) and salary:
                amount = salary.get("value") or {}
                if isinstance(amount, dict):
                    low, high = amount.get("minValue"), amount.get("maxValue")
                    amount_text = f"{low}–{high}" if low is not None and high is not None else str(amount.get("value", low if low is not None else high if high is not None else ""))
                    salary_text = " ".join(str(v) for v in (amount_text, salary.get("currency", ""), amount.get("unitText", "")) if v)
            page_url = value.get("mainEntityOfPage", "")
            if isinstance(page_url, dict):
                page_url = page_url.get("@id", "")
            jobs.append(Vacancy(source=source, url=value.get("url") or page_url or parser.canonical or url, title=plain_text(value.get("title", "")),
                                description=plain_text(value.get("description", "")), company=plain_text(company),
                                location=", ".join(dict.fromkeys(place)), salary=salary_text,
                                published=str(value.get("datePosted", "")), raw=json.dumps(value, ensure_ascii=False)))
    return jobs


class PublicPageAdapter:
    host = ""
    job_pattern = ""

    def collect(self, source: dict, fetcher, archive: Path) -> Collection:
        result = Collection()
        archive.mkdir(parents=True, exist_ok=True)
        seen = set()
        budget = source.get("detail_limit", 10)
        for index, url in enumerate(source["urls"]):
            try:
                raw = fetcher.get(url, self.host)
                (archive / f"search-{index}.html").write_bytes(raw)
                embedded = parse_job_page(raw, source["name"], url)
                result.jobs.extend(embedded)
                seen.update(job.url for job in embedded)
                page = PageData()
                page.feed(raw.decode("utf-8", errors="replace"))
                candidates = []
                for href in page.links:
                    target = urljoin(url, href).split("#")[0].split("?")[0]
                    if urlsplit(target).netloc == self.host and re.search(self.job_pattern, urlsplit(target).path) and target not in seen:
                        seen.add(target)
                        candidates.append(target)
                for target in candidates[:budget]:
                    budget -= 1
                    try:
                        detail = fetcher.get(target, self.host)
                        (archive / f"job-{len(seen)}-{budget}.html").write_bytes(detail)
                        jobs = parse_job_page(detail, source["name"], target)
                        if not jobs:
                            raise ValueError("No structured JobPosting found; use saved alerts/import if the page format changed")
                        result.jobs.extend(jobs)
                    except Exception as error:
                        result.failures.append(f"{source['name']} [{target}]: {error}")
                if not embedded and not candidates and not re.search(r"(?i)нічого не знайдено|вакансій не знайдено|no (?:jobs|results) found|0 ваканс", plain_text(raw.decode("utf-8", errors="replace"))):
                    raise ValueError("No vacancy links or explicit empty-search marker; access or page format needs review")
            except Exception as error:
                result.failures.append(f"{source['name']} [{url}]: {error}. Saved alerts or HTML import remain available.")
                if "403" in str(error) or "disallowed" in str(error):
                    break
        return result


class WorkUAAdapter(PublicPageAdapter):
    host = "www.work.ua"
    job_pattern = r"^/(?:en/)?jobs/\d+/?$"


class RobotaUAAdapter(PublicPageAdapter):
    host = "robota.ua"
    job_pattern = r"/(?:company\d+/)?vacancy\d+/?$"
