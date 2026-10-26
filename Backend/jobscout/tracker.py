import csv
import hashlib
import io
import json
import posixpath
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote, urlsplit
from zipfile import BadZipFile, ZipFile

from .model import Vacancy, canonical_url, normalized


TRACKER_URL = "https://docs.google.com/spreadsheets/d/1oCzB1sCmwIICx7WEa3ukGJQkNLvUEiOj0u4F_TYIbro/edit"
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


@dataclass
class TrackerEntry:
    key: str
    vacancy: Vacancy
    status: str | None
    metadata: dict


def mapped_status(value: str, sent: str, struck: bool) -> str | None:
    value = normalized(value)
    if value in {"rejected", "reject", "відмова", "відхилено"}:
        return "Rejected"
    if value in {"ignored", "archived", "closed", "withdrawn"}:
        return "Ignored"
    if value in {"sent", "applied", "screening call", "interview", "hr screen", "technical interview", "no response", "offer"}:
        return "Applied"
    if value in {"draft", "interested", "saved"}:
        return "Interested"
    if struck:
        return "Ignored"
    return "Applied" if sent else None


def _xml(data: bytes):
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Tracker XML must not contain document types or entities")
    return ET.fromstring(data)


def _sheets(data: bytes):
    with ZipFile(io.BytesIO(data)) as archive:
        if sum(item.file_size for item in archive.infolist()) > 25_000_000:
            raise ValueError("Tracker workbook exceeds the uncompressed size limit")
        strings = []
        if "xl/sharedStrings.xml" in archive.namelist():
            strings = ["".join(node.itertext()) for node in _xml(archive.read("xl/sharedStrings.xml")).findall("s:si", NS)]
        strikes, dates, styles = [], set(), []
        if "xl/styles.xml" in archive.namelist():
            style = _xml(archive.read("xl/styles.xml"))
            strikes = [font.find("s:strike", NS) is not None and font.find("s:strike", NS).get("val", "1") not in {"0", "false"} for font in style.findall("s:fonts/s:font", NS)]
            dates = {int(fmt.get("numFmtId")) for fmt in style.findall("s:numFmts/s:numFmt", NS) if re.search(r"[dy]", re.sub(r'\[[^\]]*\]|"[^"]*"|\\.', "", fmt.get("formatCode", "")), re.I)}
            styles = [(int(x.get("fontId", "0")), int(x.get("numFmtId", "0"))) for x in style.findall("s:cellXfs/s:xf", NS)]
        workbook = _xml(archive.read("xl/workbook.xml"))
        uses_1904 = workbook.find("s:workbookPr", NS)
        epoch = datetime(1904, 1, 1) if uses_1904 is not None and uses_1904.get("date1904") in {"1", "true"} else datetime(1899, 12, 30)
        relations = {node.get("Id"): node.get("Target") for node in _xml(archive.read("xl/_rels/workbook.xml.rels"))}
        for sheet in workbook.findall("s:sheets/s:sheet", NS):
            target = relations[sheet.get(f"{{{REL}}}id")]
            path = target.lstrip("/") if target.startswith("/") else posixpath.normpath("xl/" + target)
            root = _xml(archive.read(path))
            links = {}
            rel_path = posixpath.dirname(path) + "/_rels/" + posixpath.basename(path) + ".rels"
            if rel_path in archive.namelist():
                links = {node.get("Id"): node.get("Target", "") for node in _xml(archive.read(rel_path))}
            hyperlinks = {node.get("ref"): links.get(node.get(f"{{{REL}}}id"), "") for node in root.findall("s:hyperlinks/s:hyperlink", NS)}
            rows = []
            for row in root.findall("s:sheetData/s:row", NS):
                values, crossed, targets = {}, set(), {}
                for cell in row.findall("s:c", NS):
                    ref = cell.get("r", "")
                    column = re.sub(r"\d", "", ref)
                    raw = cell.findtext("s:v", "", NS)
                    value = raw
                    kind = cell.get("t", "")
                    if kind == "s":
                        value = strings[int(raw)] if raw else ""
                    elif kind == "inlineStr":
                        value = "".join(cell.find("s:is", NS).itertext())
                    font, number_format = styles[int(cell.get("s", "0"))] if styles else (0, 0)
                    if raw and kind not in {"s", "inlineStr", "str", "b", "e"} and (number_format in dates or 14 <= number_format <= 22):
                        value = (epoch + timedelta(days=float(raw))).date().isoformat()
                    if kind == "e":
                        value = ""
                    if font < len(strikes) and strikes[font]:
                        crossed.add(column)
                    formula = cell.findtext("s:f", "", NS)
                    formula_link = re.match(r'(?i)HYPERLINK\("([^"]+)"', formula)
                    targets[column] = hyperlinks.get(ref, "") or (formula_link[1] if formula_link else "")
                    values[column] = value
                rows.append((int(row.get("r", "0")), values, crossed, targets))
            yield sheet.get("name", ""), rows


def read_tracker(data: bytes, suffix: str, sheet_name: str = "iOS", source_url: str = TRACKER_URL) -> list[TrackerEntry]:
    if len(data) > 10_000_000:
        raise ValueError("Tracker file exceeds the size limit")
    if suffix.lower() == ".xlsx":
        try:
            sheets = list(_sheets(data))
        except (BadZipFile, KeyError, IndexError, ET.ParseError) as error:
            raise ValueError(f"Invalid XLSX tracker: {error}") from error
    elif suffix.lower() in {".csv", ".tsv"}:
        rows = csv.reader(io.StringIO(data.decode("utf-8-sig")), delimiter="\t" if suffix.lower() == ".tsv" else ",")
        sheets = [(sheet_name, [(i, {column: value for column, value in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", row)}, set(), {}) for i, row in enumerate(rows, 1)])]
    else:
        raise ValueError("Tracker import requires XLSX, CSV, or TSV")
    entries = []
    found_headers = False
    for name, rows in sheets:
        if not rows:
            continue
        headers = {column: normalized(value) for column, value in rows[0][1].items()}
        if not {"company", "role", "status"} <= set(headers.values()):
            continue
        found_headers = True
        for row_number, values, crossed, targets in rows[1:]:
            fields = {headers[column]: value for column, value in values.items() if column in headers}
            if not fields.get("company"):
                continue
            company = fields["company"]
            title = fields.get("role") or "Role not recorded in tracker"
            sent = fields.get("date sent", "")
            key = hashlib.sha256("\n".join(normalized(x) for x in (source_url, name, company, title, sent)).encode()).hexdigest()
            row_url = source_url.split("#")[0] + "#range=" + quote(f"'{name}'!A{row_number}:N{row_number}", safe="")
            link_column = next((column for column, header in headers.items() if header == "link"), "E")
            link = targets.get(link_column, "") or fields.get("link", "")
            if not re.match(r"^https?://", link):
                link = ""
            recorded_link = link
            host = urlsplit(link).hostname or ""
            platform = {"www.linkedin.com": "linkedin", "linkedin.com": "linkedin", "www.work.ua": "workua", "work.ua": "workua", "robota.ua": "robota", "jobs.dou.ua": "dou", "djinni.co": "djinni"}.get(host, "")
            if urlsplit(link).hostname == "djinni.co" and "/jobs/company-" in urlsplit(link).path:
                link = ""
            struck = bool(crossed & {column for column, header in headers.items() if header in {"company", "role", "status"}})
            status = mapped_status(fields.get("status", ""), sent, struck)
            metadata = {"key": key, "sheet": name, "row": row_number, "sheet_url": row_url, "vacancy_url": link, "recorded_link": recorded_link, "platform": platform,
                        "original_status": fields.get("status", ""), "date_sent": sent, "struck_out": struck,
                        "fields": {k: v for k, v in fields.items() if k in {"date sent", "company", "role", "channel", "link", "posting age", "salary warning", "status", "last update", "follow-up due", "gaps to prep", "notes", "retrospective"}}}
            description = "Tracker entry only. Full vacancy requirements have not been imported."
            vacancy = Vacancy(source="google_sheets", url=link or row_url, title=title, company=company, description=description,
                              raw=json.dumps(metadata, ensure_ascii=False))
            entries.append(TrackerEntry(key, vacancy, status, metadata))
    if not found_headers:
        raise ValueError("No tracker tab with Company, Role, and Status headers found")
    return entries
