# Tramline for iPhone

A native iOS app for Tramline: everything `tramline gui` does, from an iPhone 15 Pro, in SwiftUI with Liquid Glass, signing in to the Pi directly. Started 2026-11-13. Its notes were written 2026-11-11, before any of it was built.

## State, 2026-11-13

- **Built and tried in the iOS Simulator** against `tramline serve --sim`: sign-in by client certificate and pinned server fingerprint, the status card, the 3D view (the Pi's own `view.js` in a `WKWebView`), Files, Printer, Schedule and More, and the hold-to-stop button above the tab bar on every tab.
- **Not yet tried:** the Secure Enclave key on a real phone, a print, tram check, upload or schedule started from the app (scripts must never send bed-clear, so these are for the user to try from the app against the simulator), ATS on a `ts.net` name, and the real Pi.
- **Decisions made:** iOS 27 minimum, free Apple ID signing (builds expire after 7 days), bundle ID `com.alar.tramline`, light and dark following the system, addresses set in the app, `raspberrypi` by default with more tried in order as fallbacks.
- **Go code isn't shared.** gomobile can't carry the Go types, would route the Secure Enclave through Go's TLS, and needs a non-standard-library module that `build.sh` refuses. The client is about 300 lines of Swift, and what's worth sharing, the 3D view, is loaded from the Pi.

## Where it lives

This repository was `tramline-ios/` inside stringing-along until 2026-11-22. It now sits beside a checkout of the server, [Moudoux/tramline](https://github.com/Moudoux/tramline), so both are in the same parent folder:

```
~/Documents/Code/
  tramline/        the server, client and desktop GUI (Go)
  tramline-ios/    this app
```

Paths written as `tramline/...` in these notes mean that sibling checkout, `../tramline/` from here. The app doesn't build against it; the notes only cite it.

## Building

From this folder:

```sh
xcodebuild test -project Tramline.xcodeproj -scheme Tramline -destination 'platform=iOS Simulator,name=iPhone 17'
```

The project file is hand-written with synchronised folders, so new files in `Tramline/` or `TramlineTests/` need no project edits. For a phone, open it in Xcode, pick your team under Signing & Capabilities, and run.

**Against the simulator without tapping,** a Debug build takes `-debugHost 127.0.0.1:18726 -debugFingerprint <server fingerprint>` and signs in without saving, to loopback addresses only, and `-debugTab files` opens another tab. It prints `tramline-phone-fingerprint:` to the console for `tramline allow`.

## Layout

| Folder | What's in it |
|---|---|
| `Tramline/Auth/` | The DER certificate builder, the Secure Enclave key and keychain identity, the saved login |
| `Tramline/API/` | Codable models from the Go structs, the URLSession client with pinning and address fallback, the limits `/gui/info` would give |
| `Tramline/Store/` | `PrinterStore`, ported from `gui.js`: polling, busy rules, the card, actions, upload. `Words` has `status.js`'s wording |
| `Tramline/Views/` | The tabs, sheets, bed map, stop button and the 3D view |
| `TramlineTests/` | Swift Testing, with JSON captured from the simulator in `Fixtures/` |

Paths here are relative to this repository, except `tramline/...`, which is the server's checkout beside it. Tramline's own notes in `tramline/notes/` are the source of truth for the server. Where these notes and the code differ, the code wins.

## What the user asked for

- An iOS app for Tramline that **matches the Tramline GUI** (`tramline gui`), so they can control and monitor everything from their iPhone 15 Pro.
- Apple's latest design language: sleek, modern, easy to use.
- **Authenticating directly with the Tramline server**, so no computer running `tramline gui` in between.
- It goes in this folder, `tramline-ios/`, beside `tramline/`. Since 2026-11-22 that's its own repository, [Moudoux/tramline-ios](https://github.com/Moudoux/tramline-ios).

## Files

| File | What's in it |
|---|---|
| [notes/auth.md](notes/auth.md) | How the phone signs in: its own key in the Secure Enclave, a self-signed certificate, the Pi's allow list and a pinned server fingerprint. The riskiest part, so it's the first thing to prove |
| [notes/api.md](notes/api.md) | Every endpoint the app uses, how often to poll and why, the JSON shapes and the constants the GUI gets from its own local server |
| [notes/design.md](notes/design.md) | Screens, how they map onto the GUI's card and tabs, the confirmations and emergency stop that must carry over, and the 3D view |
| [notes/build-and-test.md](notes/build-and-test.md) | Toolchain (Xcode isn't installed on this Mac yet), the project layout, testing against the simulator, and the open risks |

## Start here next time (from before it was built)

1. Read `tramline/notes/README.md`, `tramline/notes/gui.md` and `tramline/notes/security.md`, then these notes.
2. Install Xcode, see Toolchain in [build-and-test.md](notes/build-and-test.md). It isn't on this Mac now: `xcodebuild` fails, and only the Command Line Tools are installed.
3. **Prove the sign-in first,** before any UI: a phone-made certificate accepted by `tramline serve --sim`, see Proving it in [auth.md](notes/auth.md).
4. Then the status card and polling, then the tabs, then the 3D view.

## Decisions still open for the user

- **Minimum iOS version.** The plan assumes iOS 26 for Liquid Glass, which the iPhone 15 Pro runs. Ask which version their phone is on.
- **Signing.** A free Apple ID's builds expire after 7 days, and a paid developer account lasts a year and allows TestFlight. Ask which they have.
- **The 3D view's approach,** see The 3D view in [design.md](notes/design.md). The recommendation is reusing `shared/view.js` in a web view, served from the Pi.
- **Notifications** for a finished print or a failed tram check need something on the Pi to push them, so they aren't in the first version. See Later in [design.md](notes/design.md).

## Rules that carry over

The `tramline` skill's rules apply to this work too. The ones that matter most here:

- **Testing must not reach the real printer.** Use `tramline serve --sim` with throwaway folders in the scratchpad. On 2026-11-05 an empty `XDG_CONFIG_HOME` sent a test print to the real printer. The app keeps its own login, so it can't pick up the real one by accident, but a test build pointed at `raspberrypi:8726` is the real printer.
- **Never read secrets,** including `~/.config/tramline/client.key` and anything in `/var/lib/tramline/`.
- **Never run sudo on the Pi.** The user runs `sudo -u tramline tramline allow ...` for the phone themselves.
- **No server changes are needed** for the plan as written. If one turns out to be needed, follow "Changing Tramline" in the skill and keep `tramline/README.md`'s Features list in step.
