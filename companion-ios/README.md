# Unified Monitor (iOS)

The iPhone and iPad version of the companion app in `../companion-android`: the same printers, accounts and features, written in Swift and SwiftUI.

| Source | How it connects |
| --- | --- |
| Bambu Lab | Bambu Cloud account (REST + Bambu's MQTT broker), or a printer in LAN mode (MQTT/TLS, access code) |
| Elegoo | Elegoo Cloud account (Elegoo's own sign-in page), or a Centauri Carbon 2 on the LAN (MQTT, access code) |
| Creality | Creality Cloud account |
| Markforged | Eiger API keys |
| Klipper, OctoPrint, PrusaLink | HTTP on the local network |

Features match the Android app: live status, notifications when a print finishes, fails or pauses, Pause / Resume / Stop, temperatures, light and speed, filament slots, moves, files on the printer, print history, the camera of printers on the local network, sending sliced files (from the in-app MakerWorld / Nexprint / Creality Cloud browser, the Files app or the share sheet), and signing in from the computer by scanning the code under Accounts > Sign in on phone. The protocols and their limits are described in `../companion-android/README.md`.

Differences from Android:

- **Bambu X1 camera:** the X1 streams RTSP video, which iOS can't play without a video library, so the app says so and points to Bambu Handy. A1 and P1 cameras work.
- **Background checks:** iOS decides when an app may check in the background (usually a few times an hour while the phone is in use, never after the app was swiped away), so a notification can come later than on Android.
- **Sends** keep going for a short while when the app leaves the screen; a long upload needs the app open.

## Layout

- `Core/` — Swift package `UnifiedCore`: account model, one `PrinterSource` per service, `PrinterHub` that refreshes them in parallel, MQTT over Network.framework, the camera feeds and the phone sign-in. Runs and is tested on macOS with `swift test`.
- `App/` — SwiftUI app, accounts in the keychain (this device only), notifications, background refresh, the Agora RTM bridge for Elegoo's cloud.
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the Xcode project is generated, not checked in.

## Build

```sh
cd companion-ios/Core && swift test          # core library tests
cd .. && xcodegen generate && open UnifiedMonitor.xcodeproj
```

CI (`.github/workflows/companion_ios.yml`) builds an unsigned `UnifiedMonitor-unsigned.ipa` on every change and publishes it from `main` to the `companion-ios-latest` release.

## Installing

iOS only runs signed apps. The unsigned IPA can be signed and installed with a free Apple ID through a sideloading tool such as Sideloadly or AltStore (the install lasts 7 days, then needs refreshing), or with Xcode on a Mac. A paid Apple Developer account gives year-long installs and TestFlight.
