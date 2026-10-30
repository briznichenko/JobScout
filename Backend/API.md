# JobScout HTTP API v1

Start from the Backend directory using Python 3.12 or newer:

```sh
python3 -B -m jobscout.service --workspace "$HOME/Library/Application Support/JobScout"
```

The default address is `http://127.0.0.1:8765`. The service creates a random token in `WORKSPACE/server-token`, with mode 0600. Every route requires `Authorization: Bearer TOKEN`, including health. Copy the token into each client's connection settings. Tokens do not appear in server logs. One service process may own a workspace at a time.

JSON request and response bodies use UTF-8 and snake_case. Errors return `{ "error": "Readable explanation" }`. Common statuses: 400 malformed input or invalid settings, 401 missing/incorrect token, 404 unknown route/record/operation, 409 active scan prevents a mutation, 413 request too large, 422 backend command failed, 500 unexpected failure. Maximum request size is 16 MiB including base64 overhead. Successful responses disable HTTP caching; clients manage their own offline snapshot cache.

## Routes

- `GET /v1/health`: `{ "status": "ok", "api_version": 1 }`.
- `GET /v1/snapshot`: existing GUI snapshot: `jobs`, `sources`, `last_run`, `workspace`, `report_path`, score thresholds, and browser readiness. The last two paths belong to the server, not the phone.
- `GET /v1/vacancies`: same complete snapshot envelope, initially unpaginated. Client filters/search operate over the snapshot.
- `GET /v1/vacancies/{id}`: one vacancy using the same shape as `jobs` entries; 404 when absent.
- `PATCH /v1/vacancies/{id}/status`: `{ "status": "Interested" }`; returns snapshot. Values: `New`, `Interested`, `Applied`, `Rejected`, `Ignored`.
- `GET /v1/settings`: `{ "config": "raw TOML text" }`.
- `PUT /v1/settings`: same envelope. Parses and validates with existing crawler configuration validation before atomically replacing the file. Returns the saved envelope. Rescore existing records explicitly after changing scoring rules.
- `POST /v1/imports`: `{ "filename": "alerts.json", "content_base64": "...", "kind": "vacancies", "adapter": "dou" }`; returns snapshot. `adapter` is optional (`dou` or `djinni`); omit for normalized vacancy JSON. Other kinds: `tracker` for XLSX/CSV exports, or `source` with required `source` (`linkedin`, `workua`, `robota`). Upload bytes rather than a client filesystem path. Filenames must not contain directories. Existing source/tracker archive behavior is retained.
- `POST /v1/rescore`: empty JSON object; returns snapshot.
- `POST /v1/report`: empty JSON object; generates report on the server and returns snapshot.
- `POST /v1/scans`: empty JSON object; returns 202 and a scan operation.
- `GET /v1/scans/current`: `{ "operation": null }` before any scan; otherwise current/latest scan operation in the wrapper.
- `GET /v1/scans/{id}`: scan operation; 404 for unknown/expired IDs.
- `POST /v1/scans/{id}/cancel`: empty JSON object; returns operation. Idempotent after completion. Initially it may still be `running` while the crawler handles cancellation.

A scan operation has `id` (opaque string), `state` (`running`, `completed`, `cancelled`, `failed`), `message` (readable string), `started` (ISO 8601 UTC), and `finished` (ISO 8601 UTC or null). Progress is coarse lifecycle progress; the service does not invent a percentage or ETA.

## Scan ownership and persistence

The service launches the existing crawler in a child process with its own process session. HTTP client disconnection, app suspension, UI task cancellation, and quitting the Mac client leave that scan running. Clients poll the operation and may reconnect through `/scans/current`. Only an explicit cancellation request signals the crawler. Its existing cooperative signal handling preserves committed data and rolls back interrupted database work.

Scans cannot overlap. The service serializes mutations and rejects settings/import/status/rescore/report writes with 409 while a scan runs; reads remain available. The existing filesystem database scan lock also protects against external CLI scans. A second service cannot acquire the workspace service lock. Do not run external CLI write commands concurrently with the service.

The latest operation is persisted under `data/server-operation.json`. If the service restarts during a running scan, that operation becomes `failed`, with an explanation; completed operations retain their state. Up to 100 operations are kept in memory; only the latest survives restart. A graceful service shutdown requests cancellation. A forced kill can leave a crawler child running temporarily, but its database scan lock still prevents overlapping crawler work.

## LAN and transport

Enable LAN binding explicitly with `--host 0.0.0.0` and use the Mac's LAN address on iOS. Permit incoming connections through the Mac firewall if prompted. iOS requests local network permission and accepts a manually entered server address. The Mac must remain awake and reachable.

Plain HTTP exposes the bearer token and vacancy data to network observers. Use it only on a trusted private LAN. For encrypted transport, supply `--cert /absolute/server-cert.pem --key /absolute/server-key.pem` and use `https://...`; clients require a certificate trusted by their OS and valid for the configured hostname. No certificate trust bypass is implemented. Do not forward the HTTP port to the internet. For optional Bonjour discovery on macOS, add `--bonjour` to a LAN-bound service. It publishes `_jobscout._tcp` with API-version and TLS flags only. In iOS Connection settings choose **Find servers on this network**, select an address, verify it belongs to your Mac, then enter its token. Discovery is unauthenticated and never transfers a token. Manual addresses remain supported. Network multicast restrictions can prevent discovery even when a manual connection works.

## Startup at login

Generate a LaunchAgent definition from a stable Backend path (not a temporary build directory):

```sh
python3 -m jobscout.service_login --workspace "$HOME/Library/Application Support/JobScout" --host 0.0.0.0 --output /tmp/ua.andrii.JobScout.service.plist
```

Review the generated plist, then install and load it explicitly:

```sh
mkdir -p "$HOME/Library/LaunchAgents"
cp /tmp/ua.andrii.JobScout.service.plist "$HOME/Library/LaunchAgents/ua.andrii.JobScout.service.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/ua.andrii.JobScout.service.plist"
```

Stop an existing manually started service before loading; the workspace lock prevents duplicate owners. The generator also accepts `--port`, `--cert`, `--key`, and `--bonjour`. Its paths are absolute and use the generating Python interpreter. Logs live under `WORKSPACE/data/logs`. The generator never installs or loads the agent itself. Disable with `launchctl bootout "gui/$(id -u)/ua.andrii.JobScout.service"` and remove the installed plist. Login startup requires the user to log in; it does not wake a sleeping Mac.
