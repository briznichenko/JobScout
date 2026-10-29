import json
from email import policy
from email.parser import BytesParser
from pathlib import Path
from urllib.parse import urlsplit

from .model import Vacancy, canonical_url
from .parsers import plain_text
from .sources import Collection
from .tracker import read_tracker
from .websources import PageData, parse_job_page


HOSTS = {"workua": {"work.ua", "www.work.ua"}, "robota": {"robota.ua"}, "linkedin": {"linkedin.com", "www.linkedin.com"}}


def parse_alert(data: bytes, source: str) -> list[Vacancy]:
    message = BytesParser(policy=policy.default).parsebytes(data)
    body = message.get_body(preferencelist=("html", "plain"))
    if body is None:
        raise ValueError("No readable email body")
    content = body.get_content()
    page = PageData()
    page.feed(content)
    jobs, seen = [], set()
    anchors = page.anchors
    if body.get_content_subtype() == "plain":
        import re
        anchors = [(url, "") for url in re.findall(r'https?://[^\s<>"\]]+', content)]
    for link, title in anchors:
        host = urlsplit(link).hostname
        if host not in HOSTS[source]:
            continue
        path = urlsplit(link).path
        is_job = "/jobs/view/" in path if source == "linkedin" else "/jobs/" in path if source == "workua" else "/vacancy" in path
        if not is_job:
            continue
        url = canonical_url(link)
        if url in seen:
            continue
        seen.add(url)
        title = title if title and title.lower() not in {"view job", "see job", "apply", "apply now"} else "Role not provided in saved alert"
        jobs.append(Vacancy(source=source, url=url, title=title, description="Saved email alert only. Full vacancy requirements have not been imported; review the original job before deciding.",
                            published=str(message.get("Date", "")), raw=message.as_string()))
    if not jobs:
        raise ValueError("No direct vacancy links in alert; tracking/login links are not followed. Import a normalized JSON entry instead.")
    return jobs


def read_source_file(path: Path, source: str) -> list[Vacancy]:
    raw = path.read_bytes()
    if len(raw) > 10_000_000:
        raise ValueError("Import file exceeds the size limit")
    if path.suffix.lower() == ".json":
        values = json.loads(raw)
        if not isinstance(values, list):
            raise ValueError("Expected an array of vacancy objects")
        return [Vacancy(**(value | {"source": source})) for value in values]
    if path.suffix.lower() == ".eml":
        return parse_alert(raw, source)
    if path.suffix.lower() in {".html", ".htm"}:
        if source == "linkedin":
            raise ValueError("LinkedIn accepts saved email alerts or normalized JSON, not scraped HTML")
        jobs = parse_job_page(raw, source, "")
        if not jobs:
            raise ValueError("Saved page has no complete vacancy with an original URL; save the rendered detail page, not the search page")
        return jobs
    raise ValueError("Supported source imports: JSON, EML, and rendered vacancy HTML")


def collect_local(source: dict, workspace: Path) -> tuple[Collection, list]:
    result, entries = Collection(), []
    directory = workspace / source.get("directory", f"imports/{source['name']}")
    directory.mkdir(parents=True, exist_ok=True)
    if source["adapter"] == "tracker":
        files = [p for p in directory.iterdir() if p.is_file() and p.suffix.lower() in {".xlsx", ".csv", ".tsv"}]
        for path in sorted(files, key=lambda p: p.stat().st_mtime)[-1:]:
            if path.suffix.lower() not in {".xlsx", ".csv", ".tsv"}:
                continue
            try:
                entries.extend(read_tracker(path.read_bytes(), path.suffix, source_url=source.get("sheet_url", "")))
            except Exception as error:
                result.failures.append(f"{source['name']} [{path.name}]: {error}")
    else:
        for path in sorted(directory.iterdir()):
            if path.suffix.lower() not in {".json", ".eml", ".html", ".htm"}:
                continue
            try:
                result.jobs.extend(read_source_file(path, source["name"]))
            except Exception as error:
                result.failures.append(f"{source['name']} [{path.name}]: {error}")
    return result, entries
