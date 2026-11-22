# Updater

Unified Slicer combines OrcaSlicer with code taken from ElegooSlicer, Unlayered Slicer and the
vendor plug-ins. Users never update those parts one by one: every change reaches them as a
Unified Slicer release of this repository, and the app follows that single feed.

## In the app

`UnifiedUpdater` (`src/slic3r/GUI/UnifiedUpdater.*`) asks the GitHub API for the latest release of
`Potatolord1965/Unified-Slicer-Vibecoded` once per start (not in stealth mode). A release is offered
when its tag `vX.Y.Z` is newer than `UNIFIED_VERSION` from `version.inc`; drafts and pre-releases are
ignored.

Nothing pops up at start. While a release is available the top bar shows an update button at its
left end; it and Help > Check for Updates open `UpdateScreen`, which shows the release notes, the
download progress and the actions.

With "Download updates automatically" on (`auto_install_updates`, default true) the package is
downloaded in the background into `<data dir>/updates/` and installed when the app closes.
"Restart and update" installs it at once and starts the app again.

## Release assets

The app installs a release only when it carries all of:

- `UnifiedSlicer-<version>-win64.zip`: the install folder, either at the zip root or inside one
  top-level folder, containing `unified-slicer.exe`. `<version>` must be the release's own version.
- `UnifiedSlicer-<version>-win64.zip.sha256`: `sha256sum` output, the SHA-256 of the zip in hex
  followed by the zip's file name.
- `UnifiedSlicer-<version>-win64.zip.sha256.sig`: the Ed25519 signature of the `.sha256` file,
  base64.

`release_unified.yml` signs the `.sha256` file with the `UPDATE_SIGNING_KEY` secret. The app checks
the signature against `RELEASE_PUBLIC_KEY` in `src/slic3r/Utils/UpdateSignature.cpp`, then that the
signed file names the package of the offered version, so neither a changed download nor an older
signed package passed off as a newer release is installed. All requests verify the server's
certificate. A release without the three assets is still shown, with a link to its page.

## Installing

The zip is downloaded straight to disk (`.part`, renamed once its hash matches the signed one) and
hashed again before installing. On exit the app starts an install helper: a PowerShell script passed
with `-EncodedCommand`, so there is no script file to swap, and run without administrator rights. It
waits for the app's process to end and runs `resources/updater/apply_update.ps1` from the install
folder, through UAC (`runas`) when that folder is not writable (Program Files).

`apply_update.ps1` copies the package into a new folder inside the install folder and checks its
hash there, so a program without the same rights can't change it between the check and the copy.
It extracts it, copies it over the install folder with `robocopy`, and deletes what the previous
version installed and this one no longer ships. `.update-manifest.txt` in the install folder lists
what the last update installed; before the first one only the `resources` folder is pruned, since
the folder may also hold the uninstaller or a portable `data_dir`. It writes nothing outside the
install folder and logs to `apply_update.log` there.

The helper then records `installed`, `failed: <reason>` or, when UAC was declined,
`declined <package>` in `<data dir>/updates/apply_update.log`, deletes the installed package, and
restarts the app when asked. Because the helper isn't elevated, neither is the restarted app. A
failure is shown on the update screen at the next start and the package is retried on the next exit.
A declined package isn't retried at exit, only from "Restart and update".

Installing is Windows only. On Linux and macOS the update screen links to the release page.

## Following upstream

`.github/workflows/upstream_watch.yml` runs daily against the versions recorded in
`.github/upstream.json`:

- OrcaSlicer shares this repository's history. A new Orca release is merged on
  `upstream/orca-<tag>` and opened as a pull request when the merge is clean, or reported as an
  issue listing the conflicting files.
- ElegooSlicer, Unlayered Slicer and Bambu Studio have separate histories, so their releases can't be
  merged. Each new one is reported as an issue for a manual port.

Pull requests opened with the workflow token don't start other workflows, so builds for them are
started by hand. Nothing upstream reaches users until a Unified Slicer release is published.
