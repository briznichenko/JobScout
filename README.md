# JobScout for macOS

A native SwiftUI GUI for the local Python job crawler. Open `JobScout.xcodeproj`, select the **JobScout** scheme and **My Mac**, then run. Requires macOS 15+ and a local Python 3.12+ installation. No Swift package dependencies or runtime AI calls.

The delivered project is at `~/Documents/xcodeprojects/JobScout`. A locally built app is included at `Build/JobScout.app`; open it directly if you do not need Xcode. It uses the same Application Support data as subsequent Xcode builds.

The app includes an independent copy of the crawler under `Backend/`; it does not depend on the original chat folder. The initial database is a SQLite backup of the vacancies collected on 2026-10-26, not demo jobs. The original CLI project and database remain available separately.

## Everyday use

- The **briefcase icon in the macOS menu bar** stays available when the window is closed. Its menu offers Search Now, Open JobScout, counts, cancellation during a search, and Quit.
- **Search → Search Now** / ⇧⌘R runs all enabled sources, updates history, and generates reports. The toolbar provides the same action. You can cancel a running search.
- **Inbox** shows active opportunities above your configured report threshold. **Strong matches** uses your configured strong-score threshold.
- Search title, company, description, location, or salary. Filter by role/source and sort by fit or discovery time.
- Select a vacancy to read its description, score breakdown, missing requirements, uncertainties, and rejection evidence.
- Change the application status to Interested, Applied, Rejected, or Ignored. This persists in SQLite and survives scans. Filter rejection is separate from application rejection.
- **Filter audit** exposes automatic rejections; **All vacancies** retains low scores and dismissed jobs.
- **Import** accepts Google Sheets tracker exports, normalized JSON alerts, DOU/Djinni RSS, Work.ua/Robota.ua rendered vacancy HTML, and saved EML job alerts. LinkedIn imports accept EML/JSON only.
- **Application tracker** shows imported application records. The detail view retains original status text, dates, notes, preparation gaps, retrospectives, and strikethrough flags. Exact vacancy URLs join existing listings without replacing their full descriptions. New live data can enrich a tracker-only entry.
- **Report** generates and opens the current Markdown summary. ⌘R reloads stored data without crawling.
- **Settings** configures your Python executable and opens the scoring rules or data folder. Edit the rules in your preferred text editor, save, then choose **Recalculate scores**.

## Added sources and tracker refresh

The configured sources are DOU, Djinni, Work.ua, Robota.ua, LinkedIn, and Google Sheets. Settings shows their collection mode, saved count, import inbox, browser search link, and latest errors. The source picker includes configured sources even before their first result. Tracker entries also appear under the original job platform when its URL identifies one.

DOU/Djinni use RSS. Work.ua and Robota.ua use optional Playwright/Chromium collection, with isolated temporary contexts, robots checks, two pages per search and 20 detail fetches per source by default. They parse JobPosting JSON-LD when present and site-specific detail markup otherwise. Overlapping searches share a detail budget and cache; cached descriptions are reused for 24 hours. New details and due refreshes share the budget. A capped search is reported as partial coverage, and absence from a search never marks a vacancy removed. Existing configs retain their explicit budgets; missing transport, pagination and refresh settings use the new defaults.

The detail budget rotates across configured searches, so iOS/macOS results cannot consume every slot before support gets a turn. Within each search, titles matching your existing Apple/support role patterns get priority for detail fetching. This only changes fetch order: other results remain eligible, and scoring and Inbox thresholds stay unchanged. Override the source's `priority_titles` regex list in TOML if needed; an empty list preserves site order.

Install browser support once from the repository root:

```sh
python3 -m venv Build/browser-runtime
Build/browser-runtime/bin/python -m pip install 'playwright>=1.48,<2'
Build/browser-runtime/bin/python -m playwright install chromium
cd Backend
../Build/browser-runtime/bin/python -m jobscout doctor
```

Set **Settings → Python executable** to the absolute path of `Build/browser-runtime/bin/python`, then choose **Save & reload**. Settings checks browser readiness using that interpreter. The virtual environment and downloaded browser are local runtime dependencies, not bundled application resources. DOU/Djinni and imports still work with standard-library Python without Playwright. Package installation follows the [Playwright library setup](https://playwright.dev/python/docs/library).

On 2026-10-29, the local browser collector fetched a Work.ua search and parsed two real details successfully; plain HTTP requests still returned 403. Robota.ua remained a loading shell in the automated browser and verification requests failed, although its pages were readable in the in-app browser. Its adapter is covered by controlled fixtures; unattended live collection is not confirmed. A verification challenge, access denial or unreadable robots policy stops collection for that site. Saved rendered detail pages with their canonical URLs, EML and JSON imports remain available.

A follow-up fixed an overly broad frame restriction: Robota.ua's Cloudflare verification iframe can load, while top-level navigation remains restricted to the source host. Live testing still received HTTP 403 from Robota.ua's page data service, so this correction does not establish working unattended collection. The source reports that denial explicitly; no verification interaction or credential/session import is automated.

LinkedIn is a saved-alert source, not a live crawler. Its published policy prohibits automated scraping. Use **Search → Open LinkedIn Search** to browse manually, then import saved email alerts with direct job links or manually normalized JSON. Tracking/login links are never followed. Email-wide text is not treated as the description of each job, preventing one vacancy's requirements from filtering another.

The supplied Google Sheet is private. A read-only XLSX export was downloaded through the signed-in browser and imported into Application Support, without changing the Sheet or its sharing settings. It contains 48 application records across iOS and Tech Support. The export and its private notes are not committed or bundled in the app.

To refresh it, download **File → Download → Microsoft Excel (.xlsx)** in Google Sheets, then choose **Import → Google Sheets tracker export…** in JobScout. XLSX preserves both tabs and strikethrough; CSV/TSV can import a single tab but do not carry formatting. The app retains the latest export under `imports/google_sheets/` and reprocesses it during Search Now. This is a local-export workflow, not authenticated background Google Sheets synchronization.

Sent, screening, interview, no-response, and offer statuses map to Applied; explicit rejection maps to Rejected; draft/saved maps to Interested. Strikethrough alone does not imply employer rejection. Original text is always preserved. Reimport updates a mapped status only if you have not changed it locally. Tracker notes and salary warnings remain distinct from current vacancy requirements and published compensation. Rows without a role or vacancy URL are retained with an explicit missing-value label and a link to the tracker row.

Put permitted saved files in `imports/workua/`, `imports/robota/`, or `imports/linkedin/`, or import them through the GUI. Search Now ingests them even when live collection is blocked. After upgrading, missing source definitions are appended to your existing config once, with a backup at `config.before-sources.toml`; existing profile and source settings are preserved.

## Data and runtime

Live data is stored in `~/Library/Application Support/JobScout/`:

- `config.toml`: your own copy of profile, filters, sources, and weights.
- `data/jobs.sqlite`: persistent vacancies, history, and statuses.
- `data/raw/`: archived feeds and rendered pages, including bounded failure diagnostics.
- `reports/`: Markdown reports and rejection audits.
- `imports/`: private tracker exports and saved source files.

The app copies the bundled config and seed database only when the respective destination files do not exist. Rebuilds do not reset your data. Back up this directory to preserve your search history. `Seed/jobs.sqlite` is the one-time starting snapshot, not a live database; application statuses never write into the project or app bundle.

Python is discovered from common installation paths. This Mac has Python at `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3`. If your installation differs, set its absolute executable path in Settings. Python is intentionally not bundled, so distributing this personal app to another Mac requires installing Python there. The GUI communicates with it through a small versioned-by-source JSON interface (`Backend/jobscout/gui.py`). It executes arguments directly using Foundation `Process`, without a shell.

This is a local development app with App Sandbox disabled because it invokes an external Python installation and supports importing files. It is not configured for Mac App Store distribution. Normal local Xcode builds can use ad hoc signing; no Apple developer account is needed for the documented command below.

## Shared CLI and scheduling

To use the same database from Terminal, run the bundled backend source from this repository:

```sh
cd Backend
python3 -m jobscout --config "$HOME/Library/Application Support/JobScout/config.toml" scan
```

The app must have launched once to initialize that config. Use the browser-enabled interpreter above for live page collection, and the same `--config` argument for CLI status, report, and launchd commands. The GUI does not install a background schedule. A per-database file lock rejects overlapping CLI/GUI scans. See `Backend/README.md` for all crawler commands and its limitations.

## Swift decisions to study

`JobStore` is the single `@MainActor @Observable` owner of UI state. The app keeps it in `@State`; views use `@Bindable` to edit filters and selection. Observation replaces the `ObservableObject` / `@Published` pattern here: there is no event-processing pipeline that would justify adding Combine. Unlike `DispatchQueue.main.async`, `@MainActor` makes UI isolation part of the type system.

The process boundary returns immutable `Decodable & Sendable` values. Neither SQLite connections nor Foundation `Process` objects cross into UI code. `BackendClient` owns processes in an actor. Its termination handler resumes a checked continuation; process-launch failure and termination both remove the pending entry before resuming, guarding against double resume. Quitting waits for cancellation so the crawler is not left running in the background.

Awaiting a process makes the actor reentrant. The UI's busy gate remains set across that suspension, preventing a second operation from racing a scan or status update. Cancellation forwards to the actor, sends termination to Python, and waits for process exit before releasing that gate. Cancellation can happen after SQLite committed, so the app offers refresh instead of claiming a rollback. This is an interview-worthy distinction: task cancellation is a cooperative signal, not a guarantee that side effects were undone.

Python handles termination by unwinding its resource scopes: pages, Chromium and the Playwright driver close before the scan lock is released. Successful detail-cache writes survive interruption and can be ingested by a later scan. Application statuses and completed scan data remain in SQLite; a cancelled uncommitted run is rolled back.

Output goes to temporary files instead of pipes. That avoids deadlock when one output pipe fills while code drains the other. The actor cleans the temporary files on completion; neither `waitUntilExit()` nor pipe reads block the main actor.

The Swift Testing suite injects a `JobBackend` fake to test state transitions without a crawler. A separate integration test starts a real Python process, cancels it, and verifies the next request succeeds. These cover behavior that can break across actor suspensions rather than snapshotting view layout.

## Build and verify

The generated Xcode project is checked in. XcodeGen is only necessary after changing `project.yml` or the source-file inventory.

```sh
xcodebuild -project JobScout.xcodeproj -scheme JobScout \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build test CODE_SIGNING_ALLOWED=NO

cd Backend
python3 -B -m unittest discover -v
```

Use `arch=x86_64` on an Intel Mac. A normal build targets the current machine. Swift 6 language mode and complete strict-concurrency checking are enabled in the project, including the test target.

The tests cover tracker/status preservation, DOM fallbacks, pagination, cache refresh, budgets, partial failures, robots rules, access denial, scan locking and configuration migration. Optional real-Chromium tests cover delayed rendering, redirect restrictions and SIGTERM cleanup of browser descendants:

```sh
cd Backend
JOBSCOUT_BROWSER_TESTS=1 ../Build/browser-runtime/bin/python -m unittest discover -v
```

These browser tests use controlled pages and don't depend on live job sites. Test-host launches skip automatic workspace loading. Live discovery is incomplete, and regex fit scoring requires human review.
