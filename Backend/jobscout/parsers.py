import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

from .model import Vacancy


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style"}:
            self.hidden += 1
        if tag in {"p", "div", "li", "br", "h1", "h2", "h3", "h4", "tr"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style"}:
            self.hidden = max(0, self.hidden - 1)
        if tag in {"p", "div", "li", "h1", "h2", "h3", "h4", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def plain_text(html: str) -> str:
    parser = TextExtractor()
    parser.feed(html)
    return "\n".join(line for raw in "".join(parser.parts).splitlines() if (line := re.sub(r"\s+", " ", raw).strip()))


def parse_feed(data: bytes, source: str, adapter: str) -> list[Vacancy]:
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("XML entities and document types are not supported")
    root = ET.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Expected an RSS channel; source format may have changed")
    jobs = []
    for item in root.findall("./channel/item"):
        title = plain_text(item.findtext("title", ""))
        company = ""
        salary = ""
        location = ""
        if adapter == "dou":
            title, separator, company = title.rpartition(" в ") if " в " in title else title.rpartition(" at ")
            if not separator:
                title = plain_text(item.findtext("title", ""))
            if company and (match := re.search(r",\s*([$€₴].+)$", company)):
                salary = match[1]
                company = company[:match.start()]
            employer, separator, suffix = company.partition(", ")
            if separator and re.search(r"(?i)віддалено|remote|за кордоном|київ|харків|львів|киев|kyiv|kharkiv|lviv|івано-франківськ|дніпро|одеса|варшава|warsaw", suffix):
                company, location = employer, suffix
        description = item.findtext("{http://purl.org/rss/1.0/modules/content/}encoded") or item.findtext("description", "")
        jobs.append(Vacancy(source=source, url=item.findtext("link", ""), title=title,
                            description=plain_text(description), company=company,
                            location=location, salary=salary, published=item.findtext("pubDate", ""),
                            raw=ET.tostring(item, encoding="unicode")))
    return jobs
