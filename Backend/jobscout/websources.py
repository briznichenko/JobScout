import json
import re
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlsplit

from .model import Vacancy
from .parsers import plain_text
from .sources import Collection
from .dom import Document
from .browser import AccessDenied


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
        try:
            values = list(_objects(json.loads(block)))
        except (ValueError, TypeError):
            continue
        for value in values:
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
    if not jobs and source in {"workua", "robota"}:
        job = parse_dom_job(data, source, url)
        if job:
            jobs.append(job)
    return jobs


def text(node):
    return plain_text(node.html()) if node else ""


def parse_dom_job(data, source, url):
    root = Document(data).root
    description = root.find(lambda n: n.attrs.get("id") == ("job-description" if source == "workua" else "description-wrap"))
    title = root.find(lambda n: n.tag == "h1")
    if not text(description) or not text(title):
        return None
    canonical = root.find(lambda n: n.tag == "link" and n.attrs.get("rel") == "canonical")
    og_url = root.find(lambda n: n.tag == "meta" and n.attrs.get("property") == "og:url")
    url = job_url(url or (canonical.attrs.get("href", "") if canonical else "") or (og_url.attrs.get("content", "") if og_url else ""),
                  "www.work.ua" if source == "workua" else "robota.ua")
    if not url:
        return None
    company = location = salary = published = ""
    if source == "workua":
        company = text(root.find(lambda n: n.tag == "a" and re.match(r"^/(?:en/)?jobs/by-company/\d+/?$", n.attrs.get("href", "")) and text(n)))
        location = text(root.find(lambda n: n.tag == "li" and n.find(lambda x: x.has_class("glyphicon-remote") or x.has_class("glyphicon-map-marker"))))
        salary_node = root.find(lambda n: n.has_class("glyphicon-hryvnia-fill") or n.has_class("glyphicon-hryvnia") or n.has_class("glyphicon-money"))
        if salary_node:
            salary = text(salary_node.parent)
        date = root.find(lambda n: n.tag == "time" and n.attrs.get("datetime"))
        if date:
            published = date.attrs["datetime"]
        else:
            date = root.find(lambda n: n.tag == "li" and re.match(r"(?:Вакансія від|Job from)", text(n)))
            published = re.split(r"[·•]", text(date))[0].strip()
    else:
        scope = root.find(lambda n: n.tag == "lib-content") or root
        company = text(scope.find(lambda n: n.tag == "a" and re.match(r"^/(?:ru/|en/)?company\d+/?$", n.attrs.get("href", ""))))
        location = text(scope.find(lambda n: n.attrs.get("data-id") == "vacancy-city"))
        remote = scope.find(lambda n: n.tag == "alliance-vac-list-status-label" and re.search(r"(?i)віддал|удален|remote", text(n)))
        if remote:
            location = "; ".join(filter(None, [location, text(remote)]))
        salary = text(scope.find(lambda n: n.attrs.get("data-id") == "vacancy-salary"))
        if not salary:
            header = title.parent.parent if title.parent and title.parent.parent else scope
            salary = text(header.find(lambda n: n.tag == "span" and re.search(r"\d[\d\s\u2009\u202f–—-]*(?:₴|грн|UAH|USD|\$|€)", text(n))))
        published = text(scope.find(lambda n: n.has_class("tooltip-inner")))
    return Vacancy(source=source, url=url, title=text(title), description=text(description), company=company,
                   location=location, salary=salary, published=published, raw=data.decode("utf-8", errors="replace"))


def job_url(url, host):
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.netloc != host:
        return ""
    if host == "www.work.ua":
        match = re.fullmatch(r"/(?:en/)?jobs/(\d+)/?", parts.path)
        return f"https://{host}/jobs/{match[1]}/" if match else ""
    match = re.fullmatch(r"/(?:ru/|en/)?(company\d+/)?vacancy(\d+)/?", parts.path)
    return f"https://{host}/{match[1] or ''}vacancy{match[2]}" if match else ""


def identity(url):
    return re.search(r"(?:/jobs/|vacancy)(\d+)", url)[1]


def page_number(url):
    parts = urlsplit(url)
    match = re.search(r"(?:;|/)page=(\d+)(?:;|$)", parts.path)
    return int(match[1] if match else parse_qs(parts.query).get("page", ["1"])[0])


def parse_search(data, url, host):
    root = Document(data).root
    scope = root.find(lambda n: n.attrs.get("id") == "pjax-jobs-list") if host == "www.work.ua" else root.find(lambda n: n.tag == "alliance-jobseeker-desktop-vacancies-list")
    candidates = {}
    if scope:
        for node in scope.walk():
            if node.tag != "a":
                continue
            ancestor = node.parent
            eligible = False
            excluded = False
            while ancestor and ancestor is not scope:
                eligible |= ancestor.tag == "h2" if host == "www.work.ua" else ancestor.tag == "alliance-vacancy-card-desktop"
                excluded |= "recommended" in ancestor.tag or "hot-vacancies" in ancestor.tag
                ancestor = ancestor.parent
            target = job_url(urljoin(url, node.attrs.get("href", "")), host)
            if eligible and not excluded and target:
                candidates[identity(target)] = target
    if not candidates and not re.search(r"(?i)вакансій не знайдено|вакансии не найдены|нічого не знайдено|ничего не найдено|no (?:jobs|results) found|\b0 ваканс", text(root)):
        raise ValueError("No search cards or explicit empty-search marker; page loading or format needs review")
    current = page_number(url)
    pages = []
    base_path = re.sub(r"/params;.*$", "", urlsplit(url).path).rstrip("/")
    for node in root.walk():
        if node.tag != "a" or not node.attrs.get("href"):
            continue
        ancestor = node.parent
        pagination = "next" in node.attrs.get("rel", "").split()
        while ancestor:
            pagination |= ancestor.has_class("pagination") or ancestor.tag == "santa-pagination-with-links"
            ancestor = ancestor.parent
        if not pagination:
            continue
        target = urljoin(url, node.attrs["href"]).split("#")[0]
        parts = urlsplit(target)
        if parts.scheme != "https" or parts.netloc != host:
            continue
        if re.sub(r"/params;.*$", "", parts.path).rstrip("/") != base_path:
            continue
        try:
            if page_number(target) == current + 1:
                pages.append(target)
        except (ValueError, TypeError, AttributeError):
            continue
    return list(candidates.values()), next(iter(pages), None)


class PublicPageAdapter:
    host = ""

    def collect(self, source: dict, fetcher, archive: Path, *, browser=None, cache=None) -> Collection:
        result = Collection()
        archive.mkdir(parents=True, exist_ok=True)
        candidates = {}
        visited = set()
        stopped = False

        def load(url, detail=False):
            if source.get("transport", "http") == "browser":
                if browser is None:
                    raise ValueError("Browser transport requires a browser session")
                return browser.get(url, self.host, detail=detail, adapter=source["adapter"])
            return fetcher.get(url, self.host)

        for index, url in enumerate(source["urls"]):
            for page_index in range(source.get("page_limit", 2)):
                if not url or url in visited or stopped:
                    break
                visited.add(url)
                try:
                    raw = load(url)
                    (archive / f"search-{index}-{page_index}.html").write_bytes(raw)
                    links, following = parse_search(raw, url, self.host)
                    candidates.update((identity(target), target) for target in links)
                    if following and page_index + 1 == source.get("page_limit", 2):
                        result.failures.append(f"{source['name']} [{url}]: Partial coverage: search page limit reached")
                    url = following
                except Exception as error:
                    if raw := getattr(error, "page_html", None):
                        (archive / f"failed-search-{index}-{page_index}.html").write_bytes(raw)
                    result.failures.append(f"{source['name']} [{url}]: {error}. Saved alerts or HTML import remain available.")
                    stopped = isinstance(error, AccessDenied) or any(code in str(error) for code in ("403", "429", "disallowed"))
                    break
        now = datetime.now(timezone.utc).timestamp()
        pending = []
        for key, target in candidates.items():
            entry = cache.crawl_entry(source["name"], key) if cache else None
            if entry and entry["payload"]:
                fetched = datetime.fromisoformat(entry["fetched"]).timestamp()
                if now - fetched < source.get("refresh_hours", 24) * 3600:
                    result.jobs.append(Vacancy(**json.loads(entry["payload"])))
                    continue
            pending.append((key, target, entry))
        pending.sort(key=lambda item: item[2]["attempted"] if item[2] else "")
        new = [item for item in pending if not item[2] or not item[2]["payload"]]
        refresh = [item for item in pending if item[2] and item[2]["payload"]]
        pending = []
        for index in range(max(len(new), len(refresh))):
            if index < len(refresh):
                pending.append(refresh[index])
            if index < len(new):
                pending.append(new[index])
        budget = source.get("detail_limit", 10)
        if len(pending) > budget:
            result.failures.append(f"{source['name']} [details]: Partial coverage: {len(pending) - budget} detail pages deferred by budget")
        for key, target, entry in pending[:budget] if not stopped else []:
            if cache:
                cache.crawl_attempt(source["name"], key)
            try:
                raw = load(target, detail=True)
                (archive / f"job-{key}.html").write_bytes(raw)
                jobs = parse_job_page(raw, source["adapter"], target)
                if len(jobs) != 1:
                    raise ValueError("Expected one complete vacancy description; page format needs review")
                job = jobs[0]
                job.source = source["name"]
                job.url = target
                result.jobs.append(job)
                if cache:
                    cache.crawl_save(source["name"], key, job)
            except Exception as error:
                if raw := getattr(error, "page_html", None):
                    (archive / f"failed-job-{key}.html").write_bytes(raw)
                result.failures.append(f"{source['name']} [{target}]: {error}")
                if isinstance(error, AccessDenied) or any(code in str(error) for code in ("403", "429", "disallowed")):
                    break
        return result


class WorkUAAdapter(PublicPageAdapter):
    host = "www.work.ua"


class RobotaUAAdapter(PublicPageAdapter):
    host = "robota.ua"
