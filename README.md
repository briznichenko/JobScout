# JobScout for macOS

A native SwiftUI GUI for the local Python job crawler. Open `JobScout.xcodeproj`, select the **JobScout** scheme and **My Mac**, then run. Requires macOS 15+ and a local Python 3.12+ installation. No Swift package dependencies or runtime AI calls.

The delivered project is at `~/Documents/xcodeprojects/JobScout`. A locally built app is included at `Build/JobScout.app`; open it directly if you do not need Xcode. It uses the same Application Support data as subsequent Xcode builds.

The app includes an independent copy of the crawler under `Backend/`; it does not depend on the original chat folder. The initial database is a SQLite backup of the vacancies collected on 2026-10-26, not demo jobs. The original CLI project and database remain available separately.

## Everyday use

- **Scan** / ⇧⌘R fetches DOU and Djinni feeds, updates history, and generates reports. You can cancel a running scan.
- **Inbox** shows active opportunities above your configured report threshold. **Strong matches** uses your configured strong-score threshold.
- Search title, company, description, location, or salary. Filter by role/source and sort by fit or discovery time.
- Select a vacancy to read its description, score breakdown, missing requirements, uncertainties, and rejection evidence.
- Change the application status to Interested, Applied, Rejected, or Ignored. This persists in SQLite and survives scans. Filter rejection is separate from application rejection.
- **Filter audit** exposes automatic rejections; **All vacancies** retains low scores and dismissed jobs.
- **Import** accepts normalized JSON alerts or saved DOU/Djinni RSS. The remaining four platforms use file import.
- **Report** generates and opens the current Markdown summary. ⌘R reloads stored data without crawling.
- **Settings** configures your Python executable and opens the scoring rules or data folder. Edit the rules in your preferred text editor, save, then choose **Recalculate scores**.

## Data and runtime

Live data is stored in `~/Library/Application Support/JobScout/`:

- `config.toml`: your own copy of profile, filters, sources, and weights.
- `data/jobs.sqlite`: persistent vacancies, history, and statuses.
- `data/raw/`: archived RSS responses.
- `reports/`: Markdown reports and rejection audits.

The app copies the bundled config and seed database only when the respective destination files do not exist. Rebuilds do not reset your data. Back up this directory to preserve your search history. `Seed/jobs.sqlite` is the one-time starting snapshot, not a live database; application statuses never write into the project or app bundle.

Python is discovered from common installation paths. This Mac has Python at `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3`. If your installation differs, set its absolute executable path in Settings. Python is intentionally not bundled, so distributing this personal app to another Mac requires installing Python there. The GUI communicates with it through a small versioned-by-source JSON interface (`Backend/jobscout/gui.py`). It executes arguments directly using Foundation `Process`, without a shell.

This is a local development app with App Sandbox disabled because it invokes an external Python installation and supports importing files. It is not configured for Mac App Store distribution. Normal local Xcode builds can use ad hoc signing; no Apple developer account is needed for the documented command below.

## Shared CLI and scheduling

To use the same database from Terminal, run the bundled backend source from this repository:

```sh
cd Backend
python3 -m jobscout --config "$HOME/Library/Application Support/JobScout/config.toml" scan
```

The app must have launched once to initialize that config. Use the same `--config` argument for CLI status, report, and launchd commands. The GUI does not install a background schedule. Avoid a manual scan while a scheduled CLI scan is running; the GUI serializes its own operations, while SQLite protects commits across processes. See `Backend/README.md` for all crawler commands and its limitations.

## Swift decisions to study

`JobStore` is the single `@MainActor @Observable` owner of UI state. The app keeps it in `@State`; views use `@Bindable` to edit filters and selection. Observation replaces the `ObservableObject` / `@Published` pattern here: there is no event-processing pipeline that would justify adding Combine. Unlike `DispatchQueue.main.async`, `@MainActor` makes UI isolation part of the type system.

The process boundary returns immutable `Decodable & Sendable` values. Neither SQLite connections nor Foundation `Process` objects cross into UI code. `BackendClient` owns processes in an actor. Its termination handler resumes a checked continuation; process-launch failure and termination both remove the pending entry before resuming, guarding against double resume. Quitting waits for cancellation so the crawler is not left running in the background.

Awaiting a process makes the actor reentrant. The UI's busy gate remains set across that suspension, preventing a second operation from racing a scan or status update. Cancellation forwards to the actor, sends termination to Python, and waits for process exit before releasing that gate. Cancellation can happen after SQLite committed, so the app offers refresh instead of claiming a rollback. This is an interview-worthy distinction: task cancellation is a cooperative signal, not a guarantee that side effects were undone.

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

Verified on this Mac: native build, **9 Swift tests**, **42 Python tests**, and UI inspection of the three-column layout, status persistence, Interested folder, filter audit, settings, and a successful live scan from the GUI. The app also exposes partial-source failures and keeps existing data on errors. The retained source limitation still applies: RSS discovery is incomplete, and regex fit scoring requires human review.
