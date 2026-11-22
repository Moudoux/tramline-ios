# The API the app uses

Part of the Tramline iOS notes, see the [index](../README.md). Checked against the code on 2026-11-11: `tramline/internal/server/server.go` and `web.go` for the routes, `tramline/internal/client/client.go` for how the CLI calls them, and `tramline/internal/webui/gui/gui.js` for how the GUI uses them. `tramline/notes/api.md` has the command-by-command table.

## Two servers on one port

Port 8726 carries both, told apart by the first byte (`splitListener` in `web.go`):

- **The API,** HTTPS with a client certificate, `/v1/...`. Everything that acts, and the full status.
- **The read-only page,** plain HTTP, no certificate: `GET /api/status` and `GET /api/model/{id}`, plus the page's files under `/` and `/shared/`. It only reads what the server holds in memory, never the printer or the Hue Bridge, so polling it once a second costs nothing.

The desktop GUI uses both: its `/pi/status` and `/pi/model/{id}` are proxies for the page's two. The phone calls them directly.

## Polling, as the GUI does

From `tramline/notes/gui.md`, "How requests reach the Pi":

- `GET /api/status` (plain HTTP) **once a second** in the foreground. Stop in the background.
- `GET /v1/status` **every 5 seconds, every 2 while a tram check, copy or print preparation runs,** and never in the background, **because each call asks the Hue Bridge for the plug's state.** Don't poll it faster than the GUI does.
- `GET /v1/files` reads the card's listing from the printer, so only ask for it when the Files tab opens, after an action, when a job starts or ends, and on pull-to-refresh.
- `GET /v1/schedule` when the Schedule tab is showing and the full status changes.
- `GET /v1/events` exists for `tramline watch`, but the GUI doesn't use it. Look at it before choosing it over polling.

## Endpoints

| What | Method and path | Body, and what comes back |
|---|---|---|
| Fast status | `GET /api/status`, plain HTTP | `WebStatus`, see below |
| Moves of the current job, for the 3D view | `GET /api/model/{jobID}`, plain HTTP | Binary `TLP1`, see below. 404 if it isn't the current job or its file isn't on the Pi |
| Full status | `GET /v1/status` | `StatusResponse` |
| Plug | `POST /v1/power` | `{"on":true}` or `{"on":false}`. Off is refused while hot, printing, tramming or copying, with a 409 and the reason |
| Preheat | `POST /v1/preheat` | `{"bed":80,"nozzle":150}` → `{bed, nozzle, heaters_off_at}` |
| Cool | `POST /v1/cool` | → `{off, cancelling}`. Also cancels a running print |
| Tram check | `POST /v1/tram` | `{"bed_clear":true, "inset"?: n, "repeat"?: n}` → `TramJob` |
| Probing settings | `GET /v1/tram/info` | → list of strings |
| Mesh | `GET /v1/mesh` | → `{lines, mesh?, parse_error?}`. Refused with the plug off and during a print, tram check or copy |
| Files | `GET /v1/files` | → `{files: [FileRecord], card: [{name,size}] or null, card_note?}` |
| One file | `GET /v1/files/{name}` | → `FileRecord`, 404 if not there. Used to skip an upload the Pi already has |
| Upload | `PUT /v1/files/{name}` | The file, `Content-Type: application/octet-stream`, `X-Tramline-SHA256: <lowercase hex>`. → `FileRecord` |
| Delete | `DELETE /v1/files/{name}` | Deletes the Pi's copy **and** the card's |
| Copy to card | `POST /v1/files/{name}/copy` | `{}` → `{file, job?}`. No job means it was already on the card |
| Stop copy | `POST /v1/copy/cancel` | |
| Print | `POST /v1/print` | `{"name", "from": "pi" or "sd", "bed_clear": true}` → `PrintJob` |
| Check again after adjusting | `POST /v1/print/continue` | `{}` → `PrintJob` |
| Cancel print | `POST /v1/cancel` | |
| Emergency stop | `POST /v1/estop` | → `{m112, plug_off, problems?}` |
| Schedule | `POST /v1/schedule` | `{"name", "from", "at": RFC 3339, "bed_clear": true}` → `ScheduledPrint` |
| Scheduled prints | `GET /v1/schedule` | → `[ScheduledPrint]`, including ended ones |
| Cancel a schedule | `POST /v1/schedule/{id}/cancel` | → `ScheduledPrint` |
| Hue pairing | `POST /v1/hue/pair` | After the bridge's button is pressed |
| Hue plugs | `GET /v1/hue/plugs` | → `[{id, name, archetype, on}]` |

**Not in the app:** `PUT /v1/update`, which the GUI leaves out too. `init`, `allow`, `revoke`, `clients` and `fingerprint` only run on the Pi.

Errors come back as `{"error": "..."}` with a status code. Show the message as it comes, as the GUI does: the server's safety rules decide, not the app.

## JSON shapes

Field names as sent, from the Go structs. `?` means omitted when empty. Times are RFC 3339 with fractional seconds, so the decoder needs `ISO8601DateFormatter` with `.withFractionalSeconds`, falling back to without.

- **WebStatus** (`/api/status`): `version`, `simulated?`, `connected`, `temps?` {`nozzle`, `nozzle_target`, `bed`, `bed_target`}, `print?` WebPrint, `tramming?`, `copy?` {`name`, `bytes`, `total_bytes`}, `scheduled?` [{`id`, `name`, `from`, `at`, `state`, `ended?`, `reason?`}].
- **WebPrint:** `id`, `name`, `mode` (`stream` or `sd`), `state`, `pos`, `size`, `moved_ago` (seconds), `run_seconds`, `elsewhere?`, `link_lost?`, `parked?`, `stopping?`, `check?` TramResult, `turn?`, `note?`, `error?`.
- **StatusResponse** (`/v1/status`): `version`, `simulated?`, `printer` {`connected`, `firmware?`, `temps?`, `temps_at?`}, `plug?` {`name?`, `on`, `error?`}, `heaters_off_at?`, `heat_problem?`, `tram?` TramJob, `copy?` CopyJob, `print?` PrintJob, `scheduled?` [ScheduledPrint].
- **PrintJob:** as WebPrint, plus `sd_name`, `schedule_id?`, `pre_check?`, `resends?`, `nudges?`, `soak_pending?`, `soak_until?`, `checks?`, `mesh?` {`point`, `of`, `started_at`, `point_at`, `point_seconds?`}, `mesh_read?` {`read_at`, `mesh?` MeshReport, `error?`}, `started_at`, `moved_at`, `finished_at?`.
- **TramResult:** `relative_mm` [4], `range_mm`, `pass`, `corner?`, `action?` (`raise` or `lower`). Corners are in the order front-left, front-right, back-right, back-left.
- **TramJob:** `id`, `state` (`running`, `done`, `failed`), `step?`, `inset`, `repeat`, `temps`, `rounds` [{`readings` [{`corner`, `x`, `y`, `z`}] or null, `result?`}], `result?`, `spread_mm?` [4], `parked`, `error?`, `started_at`, `finished_at?`, `phase?` (`homing`, `probing`, `parking`), `target?` {`corner?`, `x`, `y`, `z?`}, `step_seconds?`.
- **CopyJob:** `id`, `name`, `sd_name`, `state` (`running`, `verified`, `failed`), `lines`, `total_lines`, `bytes`, `total_bytes`, `window`, `resends`, `timeouts`, `error?`, `started_at`, `finished_at?`.
- **FileRecord:** `name`, `sha256`, `size`, `info` {`lines`, `sd_size`}, `uploaded_at`, `sd_name`, `on_card`, `sd_state?`, `sd_error?`. `sd_state` is empty, `running`, `verified` or `failed`: a finished copy is **`verified`** (`CopyDone` in `upload.go`). **The desktop GUI checks for `"done"` instead** (`cardState()` and `updateRun()` in `gui.js`), which looks like a bug there: a copied file would show "Pi only" and never be offered for printing from the card. Found 2026-11-11 from reading the code, not tried. The user hasn't decided whether to fix it in the GUI. The app should use `verified`.
- **ScheduledPrint:** `id`, `name`, `from`, `at`, `state`, `job_id?`, `check?`, `final_check?`, `reason?`, `bed_clear_at`, `ended_at?`.
- **MeshReport:** `z` [[number or null]], `z[j][i]` with column i from the left and row j from the front, `valid`, `slot?`, `active?`.

**States.** Print: `heating`, `soaking`, `checking`, `adjusting`, `starting`, `running`, `cancelling`, then `finished`, `cancelled`, `failed`, `unknown`, or `scheduled` for the check made when scheduling. Schedule: `checking`, `waiting`, `starting`, `printing`, then `finished`, `failed`, `cancelled`, `missed`, `unknown`. Decode states as strings, not a closed enum, so a new one from a newer server doesn't break decoding.

## The model, `TLP1`

From `tramline/internal/gcode/path.go`, little-endian:

- Header, 12 bytes: `"TLP1"`, the move count (uint32), the file's total seconds (float32).
- 24 bytes per move: X, Y, Z (float32, mm, where the move ends), Seconds (float32, how far into the file it ends), End (uint32, the file position just after its line, the same measure as a job's `pos`), flags (uint32, bit 0 means it extrudes).

`shared/view.js`'s `Model` class turns `pos` into a layer and time left, see The 3D view in [design.md](design.md).

## Constants the GUI gets from its own server

`/gui/info` is served by `tramline gui` on the computer, not by the Pi, so the phone has to hold these itself. Keep them in one file, with a comment pointing at where they come from:

- Maximum upload: 256 MB (`server.MaxUpload`).
- Tram tolerance: 0.05 mm (`tram.Tolerance`).
- Copy speed: `copyBytesPerSecond` in `upload.go`, about 14 KB/s, used by `server.CopyEstimate`.
- Shortest schedule lead: 15 minutes (`server.ScheduleMinLead`). Schedules can be at most 30 days away.
- File names: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (`FILE_NAME` in `gui.js`), and the GUI's `safeName` cleans a name up to fit, such as `fit test (v2).gcode` to `fit_test_v2.gcode`.

If these drift, a small read-only `GET /v1/info` on the Pi would fix it for good. That's a server change, so ask first.
