# Building and testing

Part of the Tramline iOS notes, see the [index](../README.md).

## Toolchain

**Xcode isn't installed on this Mac,** as of 2026-11-11. `xcodebuild -version` fails because the active developer directory is the Command Line Tools, and there are no iOS simulators. Swift 6.4.2 is there, from the Command Line Tools, with only the macOS SDK.

So the user needs to:

1. Install Xcode from the App Store, the version whose iOS SDK matches their phone's iOS.
2. Run `sudo xcode-select -s /Applications/Xcode.app`. That's sudo on the Mac, so the user runs it, not Claude.
3. Open Xcode once, to accept the licence and install the iOS platform.
4. Sign in with their Apple ID under Xcode, Settings, Accounts, for signing.

**Without Xcode,** the Swift code that isn't UI (the DER encoder, the models, the `TLP1` parser) can still be checked with `swiftc` against the macOS SDK, and the certificate test in [auth.md](auth.md) runs as a macOS Swift script.

## Project layout

Proposed, to be settled when building:

```
tramline-ios/
  README.md
  notes/
  Tramline.xcodeproj
  Tramline/              the app, in Xcode 16's synchronised folder, so new files need no project edits
    App/                 app entry, the root view choosing sign-in or the tabs
    Auth/                Secure Enclave key, DER certificate, keychain identity, saved login
    API/                 URLSession client with the TLS delegate, endpoints, Codable models
    Store/               one @Observable store: polling, actions, the busy rules
    Views/               Now, Files, Printer, Schedule, More, the run and tram sheets, bed map, stop button
    View3D/              the WKWebView, its scheme handler and the small page that hosts view.js
    Theme/               the colours and status words
    Assets.xcassets
  Config/Info.plist      ATS and local network keys, kept outside the synchronised folder
  TramlineTests/         DER encoding, decoding real status JSON, the TLP1 parser, safeName
```

- **Create the project in Xcode** rather than writing `project.pbxproj` by hand, then move the sources in.
- **Bundle ID:** ask the user. Something under their own reverse domain.
- **Swift language mode:** Swift 6 with strict concurrency is what Xcode starts new projects on. The URLSession delegate and Security framework calls are where it'll complain. Decide when building rather than in advance.
- **No packages.** Tramline's own rule is the standard library only. The app equivalent is Apple's frameworks only, which is enough: Security, CryptoKit for SHA-256, Foundation, SwiftUI, WebKit.
- **Not in git:** add `xcuserdata/`, `DerivedData/` and `*.xcuserstate` to the repository's `.gitignore`.
- **Release workflow:** `.github/workflows/tramline.yml` builds the Go binaries. Leave the app out of it to start with, as building for iOS in CI needs signing secrets.

## Testing

**Against the simulator only until the sign-in and the read-only screens work.** The simulator's timings are like the real printer's (`G28` 17 s, each `G30` 5 s, `G29 P1` about a minute), see "Trying it on the simulator" in Tramline's notes.

1. **The certificate,** with `curl` against `tramline serve --sim`, see Proving it in [auth.md](auth.md).
2. **Unit tests:** the DER encoding against a known certificate, decoding status JSON captured from the simulator (save a few: idle, heating, adjusting, running, finished, with a copy, with schedules), the `TLP1` parser against a model fetched from the simulator, and `safeName`.
3. **The iOS Simulator app against the simulated server** on `127.0.0.1:18726`. `sim-gui.sh` shows how to start it with files uploaded, and `--fail-tram` gives a failed check to try the "needs you" card. Never put the real Pi's address in a test build's defaults.
4. **The real phone against the simulator,** on the Mac's LAN address, to try the Secure Enclave key, ATS and the local network prompt.
5. **The real phone against the real Pi,** read-only first: status, files, schedule list, the 3D view during a print the user starts themselves. Then, **with the user's approval each time,** as the skill requires for anything that touches the printer: power, preheat and cool, a tram check, an upload, and a print.

**How the user checks the screens:** Claude can't see the phone. Use `xcrun simctl io booted screenshot` for the iOS Simulator, and ask the user for screenshots from the phone.

## Open risks

- A Secure Enclave key as a TLS client identity, see Not proven in [auth.md](auth.md).
- ATS with a self-signed server on a `ts.net` name.
- WebGL 2 performance in `WKWebView` on a long print's model. The read-only page has been opened on a phone (Tramline's notes, "Read-only web page"), but not on a long print, as far as the notes say.
- How long `GET /v1/files` takes on the real printer during a print, as it reads the card. The GUI's notes list that as not proven.
- Uploading a large file over 5G and Tailscale.
