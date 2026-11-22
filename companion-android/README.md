# Unified Monitor (Android)

Companion app for Unified Slicer: watches every printer from your phone in one list.

| Source | How it connects |
| --- | --- |
| Bambu Lab | Bambu Cloud account (REST + Bambu's MQTT broker), or a printer in LAN mode (MQTT/TLS, access code) |
| Elegoo | Elegoo Cloud account (Elegoo's own sign-in page, report-data API), or a Centauri Carbon 2 on the LAN (MQTT, access code) |
| Creality | Creality Cloud account (device list + IoT telemetry) |
| Markforged | Eiger API keys (devices + active job) |
| Klipper, OctoPrint, PrusaLink | HTTP on the local network |

Features: send sliced files to a printer (see below), live status (progress, time left, layer, temperatures, stage) refreshed every few seconds while open, notifications when a print finishes, fails or pauses (checked every 15 minutes in the background), brand-coloured accents, dark theme by default.

The protocols are the ones Unified Slicer's desktop code uses (`src/slic3r/Utils/ElegooCloud.cpp`, `CrealityCloud.cpp`, `MarkforgedEiger.cpp`, `resources/plugins/elegoo_cc2_lan.py`); Bambu Cloud uses Bambu's public account API.

## Sign in from the computer

Accounts > **Scan computer code** (or the phone's camera app) reads the QR code Unified Slicer shows under Accounts > Sign in on phone, and signs in to the same Bambu Lab, Elegoo, Creality and Markforged accounts in one step. The computer serves them once over the local network, encrypted with a key that is only in the QR code. See `docs/HLSD/phone-sign-in.md`.

## Controls and camera

A printer's page has Pause / Resume / Stop, tap-to-set nozzle and bed temperatures, and on some printers a light switch and speed levels (`controlsFor` lists what each kind offers).

| Printer | Commands |
|---|---|
| Bambu (cloud or LAN) | MQTT request topic: `pause` / `resume` / `stop`, `print_speed`, `ledctrl`, `gcode_line` for temperatures. Firmware with authorization control refuses unsigned commands unless Developer Mode is on; the app shows the refusal. |
| Elegoo (cloud or LAN) | Methods 1021 pause, 1023 resume, 1022 stop, 1028 temperature |
| Creality cloud | `iotrouter/rpc/twoway` with `{"method":"set","params":{…}}`, as Creality Print |
| Klipper, OctoPrint, PrusaLink | Their HTTP APIs (PrusaLink: job control only) |

The camera shows only for printers added by address on the local network, and connects after a tap on Watch: Klipper / OctoPrint / PrusaLink snapshots, Bambu A1 and P1 (JPEG over TLS on port 6000), Bambu X1 (RTSP over TLS on port 322; needs LAN Only Liveview on). Bambu, Elegoo and Creality cloud video run on closed services and are not available.

## Filament, files, history and moving the head

- **Filament:** Bambu AMS (and AMS HT) trays plus the external spool, from the `ams` / `vt_tray` report; Elegoo Canvas trays from `canvas_info` in the status. The tray feeding the nozzle is outlined.
- **Move:** Home and relative X/Y/Z steps (0.1 / 1 / 10 mm) on an idle printer. Raw G-code where the printer takes it (Bambu `gcode_line`, Creality `gcodeCmd`, Moonraker), Elegoo methods 1026 / 1027, OctoPrint's printhead API. PrusaLink has no motion API.
- **Files on the printer:** Moonraker, OctoPrint and PrusaLink list their stored print files and start one.
- **History:** Bambu cloud task list (`/v1/user-service/my/tasks`) and Moonraker's job history.

Elegoo light and speed (methods 1029 / 1031) are not wired: their parameters are not published.

## Sending prints

A phone cannot slice, so the app sends printer-ready files (G-code): one downloaded in the in-app MakerWorld / Nexprint / Creality Cloud browser, or one picked from the phone.

| Printer | How the print is sent |
| --- | --- |
| Elegoo cloud | Upload to Elegoo's storage, then download (1057) and start (1020) over Agora RTM, as `ElegooCloud::send` does |
| Elegoo CC2 on LAN | Chunked HTTP upload, then start (1020) over MQTT |
| Creality cloud | Gzip, signed PUT to Creality's OSS bucket, `uploadGcode`, `addSingleTask` |
| Klipper, OctoPrint, PrusaLink | HTTP upload with print-after-upload |
| Bambu Lab | Not sent by this app: Bambu firmware only accepts print commands signed by Bambu's own apps. MakerWorld's Print link is handed to Bambu Handy |
| Markforged | Not sent: Eiger slices and queues its own jobs |

## Layout

- `core/` — plain Kotlin/JVM: account model, one `PrinterSource` per service, `PrinterHub` that refreshes them in parallel. Unit tested on the JVM.
- `app/` — Android UI (Jetpack Compose, Material 3), encrypted account store (Android Keystore AES-GCM), WorkManager background check, notifications.

## Build

Needs JDK 17+ and the Android SDK (API 36).

```
./gradlew :core:test :app:assembleRelease
```

The GitHub workflow `companion_android.yml` builds the APK on every change and, on `main`, publishes it as the `companion-latest` release.

The release APK is signed with the key in the repository secrets (`COMPANION_KEYSTORE_BASE64`), so every release installs over the last one. The package name is `app.unifiedslicer.monitor`, registered for Android developer verification with that key's SHA-256 fingerprint. Builds before 1.5 used `app.unifiedslicer.companion`; uninstall that app and install the new one.

## Notes

- Elegoo's sign-in page only issues device-API tokens to a client that presents itself as ElegooSlicer, so the sign-in web view uses ElegooSlicer's user agent (same as the desktop app).
- LAN printers are reachable only on the same network or over a VPN.
- Bambu LAN mode certificates are self-signed and are not verified; cloud connections are.
