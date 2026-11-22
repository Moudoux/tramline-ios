# Screens and design

Part of the Tramline iOS notes, see the [index](../README.md). The desktop GUI is `tramline/internal/webui/gui/` (`index.html`, `gui.js`, `gui.css`), with shared parts in `shared/`. Its design record is `tramline/notes/gui.md`, "The page".

## The look

- **Tramline's colours,** from `shared/theme.css`, dark: background `#15181c`, panel `rgba(28,32,38,0.92)`, lines `#343a43`, text `#e8eaed`, muted `#9aa3ad`, accent orange `#f0883e`, good green `#57c47a`, bad red `#f2645a`. The GUI also uses raised `#20252c` and field `#111418` (`gui.css`). The app should be dark by default, like the GUI. Ask whether a light mode is wanted.
- **Apple's current design language,** meaning Liquid Glass on iOS 26: the system `TabView` with `Tab`, which gets the glass tab bar for free, `.glassEffect()` on floating controls such as the stop button and the status card over the 3D view, `.buttonStyle(.glassProminent)` tinted orange for primary actions, sheets with detents for dialogs, SF Symbols for icons, and `.sensoryFeedback` for haptics. Check the current SDK's names when building, as these are from iOS 26's API.
- **The GUI's wording,** taken from `shared/status.js` (`STATE_TEXT`, `SCHEDULE_TEXT`, `clock`, `temp`) and `gui.js`. The badge words ("heating", "checking tram", "needs you", "printing"...), messages, confirmations and toasts should read the same on both, so port them as they are.
- **App icon:** the GUI's logo is in `gui/icon.svg` and inline in `index.html`, a little house shape. Use it in the accent orange on the dark background.

## Layout

The GUI has a 3D view filling the window, and a side panel with a status card and four tabs. On a phone:

- **Tab bar:** Now, Files, Printer, Schedule, More. The GUI has no Now tab, as its card is always visible. On a phone it needs a screen of its own.
- **Now:** the 3D view across the top half or more, with the status card in glass below or over it. The badge, file name, progress bar, and the four figures (progress, layer, time left, running for), nozzle and bed temperature with target, plug state, the message and problem lines, and the job's buttons (Check again, Cancel print, Stop copy). A failed tram check shows the bed map, verdict and advice here, as the GUI's `check-card` does. The logic to port is `showNow()` and `showJobActions()` in `gui.js`.
- **Files:** an upload button using the Files app picker (`.fileImporter` for `.gcode` and `.gco`) instead of drag and drop, with the progress bar. Also files on the Pi, newest first, each with size, lines, upload time and a chip (on card, copying N%, copy failed, Pi only), and swipe or menu actions for Print, Schedule, Copy to card and Delete. Then the card's listing, with "from here" or "not from here". Pull to refresh. Port `showFiles()`, `fileItem()` and `upload()`.
- **Also accept files shared from other apps,** such as a G-code AirDropped from the Mac, through a document type for `.gcode`. That's the phone's version of drag and drop. Ask whether it's wanted.
- **Printer:** power with a segmented On and Off, preheat with bed and nozzle steppers (defaults 80 and 150, as the GUI's), Cool down, the heaters' off time, the tram section with the bed map and Check tram, and the firmware line.
- **Schedule:** "Schedule a print", then the list, coming soonest first and ended latest first, with their checks and reasons, and Cancel on pending ones. Show the count of coming ones as the tab's badge, as the GUI's tab does.
- **More:** Hue pair and list plugs, probing settings and the mesh (text, plus the surface in the 3D view), About (app version, server version, address, the phone's fingerprint), and the sign-in settings: change server, show the phone's fingerprint again, and forget this server.

## Safety: what must carry over exactly

These come from the GUI and the skill's rules, and are the reason the GUI is safe to hand someone:

- **Bed clear:** printing, scheduling and tram checks need a "I've checked the bed is clear" toggle that **starts off every time and is never remembered.** For a schedule it reads "I've checked the bed is clear, and nothing will go on it before the print". The Start button stays disabled until it's on.
- **Print from the Pi or the card is a choice,** with neither preselected when both are possible. The card is only offered once the file is verified on it. Otherwise the Pi is selected and the card is disabled with "Copy it to the card first, from the file list."
- **The steps are spelled out** before starting, with the text from `updateRun()` in `gui.js`.
- **Confirmations** for Cancel print ("Keep printing" as the other choice), cool during a print, power off, delete (saying the card's copy goes too) and cancelling a schedule, with the dangerous button in red.
- **Emergency stop:** a round red button, always visible on every tab, **held for 0.6 seconds** with a filling ring, so a stray tap can't fire it. Use a long-press gesture with a strong haptic when it fires. Then show what the Pi says was done. If the plug isn't confirmed off, or the request failed, say "Use the printer's own switch now." Port `fireEstop()`. On a phone it could sit in the tab bar's accessory area or float at the top right; try both.
- **Busy rules:** grey out Preheat, Check tram, Schedule and the file actions while a print, tram check or copy runs, with the reason, as `busyReason()` and `applyBusy()` do. The Pi refuses anyway, this only saves a tap.
- **Schedule times:** the GUI offers at least an hour ahead, rounded up to 5 minutes. Show the chosen time back with the weekday, date and timezone (`scheduleWhen` in `status.js`).
- **The LCD's Pause isn't supported during a stream.** Say so near Cancel, or in the print's help.

## The 3D view

The GUI's centrepiece is `shared/view.js`, about 1,600 lines of WebGL 2: the bed, the toolpath as ribbons, the head following the job, the live tram probe view with reading pins, the mesh being probed, and the mesh surface. Rewriting it natively would be most of the work, and the two would drift.

**Recommendation: reuse `view.js` in a `WKWebView`, loaded from the Pi.**

- The Pi already serves `shared/view.js`, `shared/status.js` and `shared/theme.css` over plain HTTP, so the phone always runs the version that matches its server, with nothing copied into the app.
- Load a small page of the app's own through a `WKURLSchemeHandler`, such as `tramline://view/index.html`, holding just a canvas, the labels layer and a script that creates `new PrintView(canvas, id => "tramline://view/model/" + id, labels)`. The scheme handler answers `/shared/*` and `/model/{id}` by fetching from the Pi. That keeps them same-origin, as the page's model fetch would otherwise be cross-origin, and the server sends no CORS headers.
- Drive it from Swift with `evaluateJavaScript`, as `gui.js` does: `view.update(printJob)` every page poll, `view.updateTram(job, 0.05)`, `view.updateMesh(job)` and `view.updateHeights(mesh)`, with the GUI's rules for when each shows (`showTramView`, `meshShown`, `showLastMesh` in `gui.js`). Read back `view.details()` for the layer and time left, and `view.modelMissing`.
- It already handles touch: one finger turns, two pan and pinch, and a double tap resets (the "Mouse and touch" part of `view.js`). It draws less often on coarse pointers to save power.
- Set the web view's background to `#15181c` and turn off its scrolling, bouncing and link previews, so it reads as part of the app.
- `renderer.offsetX` centres the bed beside the GUI's panel. On a phone, leave it at 0 or use it if the card overlaps the view.
- **If WebGL 2 isn't available,** the view's `ok` is false. Show the GUI's message, and everything else still works.
- **The alternative,** a native RealityKit view, means reimplementing the model parsing, the layer count, the playhead (`updateTarget` and `advance`, with `LAG_MOVES` of 16 for a stream and 32 for the card, `SD_COAST_SECONDS` 50 and `SNAP_SECONDS` 30), the tram and mesh scenes and the camera. Only worth it if the web view feels wrong in use. SceneKit is deprecated, so don't start there.

## Later

- **Notifications,** such as a print finished, a tram check failed or a scheduled print missed. The phone can't poll in the background, so this needs the Pi to push through APNs, or a relay. That's a server change, so it's for a later version, and it should be discussed with the user first.
- **A Live Activity and Dynamic Island** for a running print, with progress and time left. Updating it while the app is closed needs push too. While the app is open it could update locally.
- **Widgets** need the same.
- **Shortcuts and Siri,** such as "What's the printer doing?", through App Intents, are possible without server changes, but only for read-only things. Anything that moves the printer needs the bed-clear confirmation, so not from Siri.
