# Personal JobScout

A local Python 3.12+ CLI for Andrii's Apple engineering and technical support search. SQLite stores vacancies, source entries, description versions, scan events, and application statuses. The runtime uses only Python's standard library: no subscriptions, API keys, LLM calls, backend, or frontend.

## Run

From this directory, run:

```sh
python3 --version
python3 -m jobscout scan
```

Use Python 3.12 or newer. No installation or virtual environment is required. Optionally install the CLI with `python3 -m pip install -e .` in a virtual environment; this requires setuptools for packaging, not for running the tool.

The scan prints Markdown and saves `reports/latest.md`, a numbered report, and a separate rejection audit. Data lives in `data/jobs.sqlite`; raw fetched feeds live under `data/raw/`. A scan with partial source failures still saves successful results and reports failures. Exit codes: 0 success, 1 local/configuration error, 2 one or more source failures. Reports are UTF-8.

## Small architecture

`sources.py` contains DOU and Djinni RSS adapters. `parsers.py` converts RSS and HTML descriptions into `Vacancy` objects. `scoring.py` knows nothing about websites; it evaluates a vacancy against `config.toml`. `storage.py` manages SQLite identity/history, and `reporting.py` writes concise reports. `cli.py` connects these stages. `network.py` handles HTTPS, robots rules, bounded retries, timeouts, and per-host delays.

This MVP deliberately uses published feeds instead of listing-page scraping. Both DOU's iOS category and Djinni's RSS feed were fetched successfully on 2026-10-26. Current robots rules allow these paths. Feed availability and publisher policies can change; robots checks run on every scan. Robots permission is not a substitute for site terms. See the publisher links below when maintaining adapters.

Default discovery covers DOU iOS/macOS and Support, plus Djinni iOS, Support, macOS and Swift searches. Search feeds can overlap. A successful scan is not proof of exhaustive coverage. RSS windows are limited; company, location, compensation and requirements may be missing. No authenticated results or detail-page enrichment is implemented.

- [DOU RSS](https://jobs.dou.ua/vacancies/feeds/?category=iOS)
- [DOU robots rules](https://jobs.dou.ua/robots.txt)
- [Djinni RSS](https://djinni.co/jobs/rss/?primary_keyword=iOS)
- [Djinni robots rules](https://djinni.co/robots.txt)
- [Djinni terms overview](https://guide.djinni.co/terms-of-use)

## Inspect and track applications

```sh
python3 -m jobscout list
python3 -m jobscout show 1
python3 -m jobscout status 1 Interested
python3 -m jobscout status 1 Applied
python3 -m jobscout status 2 Ignored
python3 -m jobscout list --rejected
python3 -m jobscout list --status Interested
python3 -m jobscout report
```

Statuses are `New`, `Interested`, `Applied`, `Rejected`, `Ignored`. Automatic filter rejection is a separate assessment; it does not overwrite your application status. Applied, Rejected, and Ignored entries are omitted from recommendation sections even if descriptions change. `show` includes original URLs, all captured versions, per-source records, full scoring evidence, and status history. Nothing applies to vacancies or sends messages.

A new vacancy is highlighted in its discovery scan. Subsequent scans classify it as updated or unchanged; previous active opportunities appear in a separate section. Rerendering the same scan retains its original new/updated classification. Whitespace/case, tracking parameters, and feed publication timestamp changes do not trigger updates. Description, title, company, location, or salary changes do. Update history is per source, preventing copies from alternating between “updated” on every run.

Deduplication first uses source and canonical URL. Across sources, normalized titles must match and known companies must not conflict. It then requires an identical substantial description, or matching known employer/location and at least 97% description similarity. Original source URLs remain in stored payloads. This conservative choice can leave duplicates when descriptions differ or employer names are unavailable. It also cannot always distinguish two real vacancies with identical text. Review the retained source links.

## Filtering and scoring

All configured exclusion patterns and weights are in `config.toml`. Defaults implement the supplied exclusions, conservatively:

- Explicit mandatory relocation or office attendance outside Kharkiv for named cities.
- Required commercial/production Android, KMP, Flutter, or React Native experience, where the wording ties experience to that platform.
- Explicit L1/customer-service/call-center, sales, or account-manager titles, or explicitly predominant phone work.

Ambiguous requirements, optional skills, missing salary, and uncertain geography go to manual review. A remote mention does not establish Ukraine eligibility. Office cities not covered by configured patterns remain for review. Negation and optional wording suppress hard exclusion. Conflicting clauses can escape a hard filter intentionally; the listing remains auditable.

The score is the sum of seven configurable components: role 30, skills 25, experience 10, geography/work format 15, communication 5, seniority 5, salary 10. Missing or unverified tracked mandatory skills cost 6 each, capped at 24. Every awarded component and penalty appears in the assessment. Unknown facts receive stated neutral or partial points, not a fabricated match. Scores rank candidates; they are not calibrated probabilities. “Strong” means at least 70; reports normally show at least 45 and cap output at 12 recommendations. Low scores remain in SQLite and `list`.

Profile defaults distinguish commercial skills from study/portfolio concurrency and Combine evidence. SwiftUI is included as a skill. SQL/Grafana/Elasticsearch are not assumed. Monthly USD salary targets of $2,700 for engineering and $700 for support are editable ranking preferences derived from supplied context, not hard floors or current market estimates. Salary points compare only explicit monthly USD ranges; gross/net remains unknown. Change them if your current expectations differ.

After editing rules:

```sh
python3 -m unittest discover -v
python3 -m jobscout rescore
python3 -m jobscout report
```

`rescore` changes assessments without creating discovery events or resetting statuses. Historical captured versions retain their original assessments; `runs.config` stores the configuration used for each collection. The report uses current stored assessments and current application statuses.

Regex heuristics are intentionally limited. They can miss unfamiliar wording, languages, implied requirements, technical roles disguised under generic titles, or requirements absent from feed text. They track named skills, not every technology a job might require. No automatic system can guarantee that a high score means eligibility. The rejection audit and stored low-scoring entries are the safety net for reviewing errors.

## Alerts and local import

Work.ua and Robota.ua have public-page adapters plus saved structured-HTML/EML/JSON imports. Both currently return HTTP 403 from this runtime, and searches report those failures. LinkedIn accepts saved EML alerts or normalized JSON only; no LinkedIn crawler is provided. Glassdoor remains manual JSON import. No mailbox integration, login automation, or CAPTCHA bypass is included.

Import tracker exports and saved source files:

```sh
python3 -m jobscout import-tracker tracker.xlsx
python3 -m jobscout import-tracker ios.csv --sheet-name iOS
python3 -m jobscout import-source alert.eml --source linkedin
python3 -m jobscout import-source job.html --source workua
```

The GUI additionally saves imported files to its Application Support inbox for future searches. CLI imports are one-time unless you put files into the matching configured `imports/` directory. Tracker rows preserve original statuses, strikethrough, notes, and preparation gaps; those notes are not scored as vacancy requirements. Local status edits are preserved on later tracker refreshes. Private Google Sheets need an authenticated browser export; the runtime does not read browser sessions or credentials.

`examples/alerts.json` is an importable **synthetic demonstration**, not real vacancies. Each object accepts `source`, `url`, `title`, `description`, and optional `company`, `location`, `salary`, `published`, `raw`. URLs must be HTTP(S). Keep missing details empty. Import is validated before database mutation.

Run the demo in separate storage:

```sh
python3 -m jobscout --db data/demo.sqlite --reports reports/demo import examples/alerts.json
```

For actual alerts or saved feeds:

```sh
python3 -m jobscout import my-alerts.json
python3 -m jobscout import saved-dou.xml --adapter dou --source dou
python3 -m jobscout import saved-djinni.xml --adapter djinni --source djinni
```

RSS absence never means removal. Only `import --source NAME --complete-snapshot` accepts a user assertion that the file contains that source's *entire* current inventory. Two consecutive complete snapshots missing a listing mark it potentially removed. Never use this flag for rolling RSS feeds, partial exports, or alerts. Records are retained and reappear if discovered again.

## Daily macOS execution

Generate a launch agent using the exact Python interpreter that works in your terminal:

```sh
python3 -m jobscout launchd --hour 9 --minute 0 --output com.personal.jobscout.plist
plutil -lint com.personal.jobscout.plist
```

The command only creates a plist. To install it yourself:

```sh
mkdir -p ~/Library/LaunchAgents
cp com.personal.jobscout.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.personal.jobscout.plist
```

Time uses the Mac's local timezone. A sleeping Mac may run after wake; a powered-off Mac cannot run the job. Logs are in `data/logs/`. Moving this directory or changing the Python installation requires regenerating/reinstalling the plist. macOS may require file-access permission for Documents. To stop scheduling:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.personal.jobscout.plist
```

Scheduling has not been installed automatically. Do not launch overlapping manual/scheduled scans; SQLite serializes writes, but duplicate concurrent network collection is wasteful.

## Verification and maintenance

```sh
python3 -m unittest discover -v
git diff --check
```

Tests cover synthetic accepted/rejected examples, parser fixtures, configurable exclusions, unknowns, scoring arithmetic, deduplication, history, dismissed statuses, feed failures, robots, redirects, retries, and removal safeguards. `tests/fixtures/reference.json` contains synthetic policy examples, not a dataset of jobs you previously accepted or rejected. Add your actual decisions there before tightening exclusions; check false negatives first. Fixtures use source-shaped synthetic XML; live smoke testing separately verifies current feed compatibility.

Fetches use HTTPS on the adapter's fixed host, fail closed when robots cannot be checked (except a 404 robots file), honor robots delay/request rate, and stop on access denial. Redirect targets are checked before requesting. Each request has a timeout, response-size cap, and bounded retries. A bad feed is retained for debugging and reported rather than silently treated as zero jobs. A malformed entry fails that feed instead of silently dropping records. Empty valid feeds are accepted as empty discovery windows.

The repository contains code, configuration, tests, and examples. Generated reports and data are ignored by Git. Back up `data/` and `reports/` separately if you want to retain search history. Both can contain private imported material. The tool never reads browser credentials or API keys.
