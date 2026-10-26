from dataclasses import dataclass, field
from http.client import HTTPException
from pathlib import Path

from .model import Vacancy
from .parsers import parse_feed


@dataclass
class Collection:
    jobs: list[Vacancy] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)


class RSSAdapter:
    host = ""
    kind = ""

    def collect(self, source: dict, fetcher, archive: Path) -> Collection:
        result = Collection()
        archive.mkdir(parents=True, exist_ok=True)
        for index, url in enumerate(source["urls"]):
            try:
                raw = fetcher.get(url, self.host)
                (archive / f"feed-{index}.xml").write_bytes(raw)
                result.jobs.extend(parse_feed(raw, source["name"], self.kind))
            except (OSError, ValueError, SyntaxError, HTTPException) as error:
                result.failures.append(f"{source['name']} [{url}]: {type(error).__name__}: {error}")
        return result


class DOUAdapter(RSSAdapter):
    host = "jobs.dou.ua"
    kind = "dou"


class DjinniAdapter(RSSAdapter):
    host = "djinni.co"
    kind = "djinni"


ADAPTERS = {"dou": DOUAdapter, "djinni": DjinniAdapter}


def adapter_for(kind: str):
    if kind in ADAPTERS:
        return ADAPTERS[kind]()
    from .websources import RobotaUAAdapter, WorkUAAdapter
    return {"workua": WorkUAAdapter, "robota": RobotaUAAdapter}[kind]()
