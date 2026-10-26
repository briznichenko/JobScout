import hashlib
import re
from dataclasses import asdict, dataclass, field
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().casefold()


def canonical_url(url: str) -> str:
    parts = urlsplit(url.strip())
    if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username:
        raise ValueError("Vacancy URL must be a public HTTP(S) URL without credentials")
    query = [(k, v) for k, v in parse_qsl(parts.query) if not k.startswith("utm_") and k not in {"from", "ref"}]
    fragment = parts.fragment if parts.hostname == "docs.google.com" and "/spreadsheets/" in parts.path else ""
    if parts.hostname in {"www.linkedin.com", "linkedin.com"} and (match := re.search(r"/jobs/view/(?:[^/?]*-)?(\d+)/?", parts.path)):
        return f"https://www.linkedin.com/jobs/view/{match[1]}/"
    if parts.hostname in {"jobs.dou.ua", "djinni.co", "www.work.ua", "work.ua", "robota.ua"}:
        query = []
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path or "/", urlencode(sorted(query)), fragment))


@dataclass
class Vacancy:
    source: str
    url: str
    title: str
    description: str
    company: str = ""
    location: str = ""
    salary: str = ""
    published: str = ""
    raw: str = ""
    original_url: str = ""

    def __post_init__(self):
        self.original_url = self.original_url or self.url
        self.url = canonical_url(self.url)
        if not self.title.strip() or not self.description.strip() or not self.source.strip():
            raise ValueError("Vacancy requires source, title, and description")

    def payload(self) -> dict:
        return asdict(self)

    def fingerprint(self) -> str:
        values = [self.title, self.company, self.description, self.location, self.salary]
        return hashlib.sha256("\n".join(normalized(v) for v in values).encode()).hexdigest()


@dataclass
class Assessment:
    score: int
    decision: str
    role: str
    positive: list[str] = field(default_factory=list)
    negative: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    uncertainty: list[str] = field(default_factory=list)
    rejected: list[str] = field(default_factory=list)
    components: dict[str, int] = field(default_factory=dict)

    def payload(self) -> dict:
        return asdict(self)
