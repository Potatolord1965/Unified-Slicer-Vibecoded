# Privacy

Unified Slicer and the Unified Monitor phone app are run by volunteers, not a company. Neither app
sends anything to the developers: there are no analytics, no crash reports and no Unified Slicer
servers.

## What leaves your computer or phone

| Where | What | When |
| --- | --- | --- |
| The printer services you sign in to (Bambu Lab, Elegoo, Creality, Markforged Eiger, Snapmaker) | Your sign-in, the files you print, printer commands | Only after you sign in to that service, and only to that service |
| Printers on your network (Klipper, OctoPrint, PrusaLink, LAN printers) | Print files and commands | When you add the printer and use it |
| Model sites in the Home tab (Unlayered Universe, MakerWorld, Nexprint, Snapmaker Space, Thingiverse) | Whatever those sites collect, under their own privacy policies | When you open them |
| GitHub | A request for the latest release | Once per start, to check for updates (off in stealth mode) |
| Bambu Lab's networking plug-in | What Bambu's own privacy policy describes | Only if you install it to use Bambu printers |

Each service handles your data under its own privacy policy. Unified Slicer is not affiliated with
any of them.

## What is stored on your device

- Sign-in tokens, encrypted: Windows DPAPI on Windows, the keychain on macOS and Linux, the Android
  Keystore on the phone.
- Settings, presets and filament inventory in the app's data folder.

Signing out of a service in the Accounts tab removes its token. Deleting the data folder (or
uninstalling the phone app) removes everything.

## Phone sign-in

"Sign in on phone" passes your accounts from the computer to the phone once, over your local
network, encrypted with a key that exists only in the QR code.

## Changes

If the apps ever start sending data anywhere else, this page will say so first, and the app will ask
before it does.
