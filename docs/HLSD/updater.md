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

The app installs a release only when it carries both:

- `UnifiedSlicer-<version>-win64.zip`: the install folder, either at the zip root or inside one
  top-level folder, containing `unified-slicer.exe`.
- `UnifiedSlicer-<version>-win64.zip.sha256`: the SHA-256 of the zip in hex, optionally followed by
  the file name (`sha256sum` output).

A release without them is still shown, with a link to its page.

## Installing

The zip is hashed after download and again before installing. On exit the app writes
`apply_update.ps1` next to the package and starts it hidden. The script waits for the app's process
to end, extracts the zip, copies it over the install folder with `robocopy`, deletes the package and
restarts the app when asked. When the install folder is not writable (Program Files) the script is
started with `runas`, so Windows asks for administrator rights. The script logs to
`apply_update.log`; a failure is shown on the update screen at the next start, and the package is
retried on the next exit.

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
