# Phone sign-in

**Accounts > Sign in on phone** (`src/slic3r/GUI/PhoneSignInDialog.*`) signs the Unified Monitor
Android app (`companion-android/`) in to the printer-service accounts this computer uses, with one
QR scan. The phone side is `core/handoff/SignInHandoff.kt` and `ui/add/ComputerSignInScreen.kt`.

## What is handed over

| Service | Source on the computer | Phone account |
|---|---|---|
| Bambu Lab | `PhoneSignIn::bambu_session()` (see below) | `BambuAccount` |
| Elegoo | `ElegooCloud::account()` | `ElegooAccount` |
| Creality Cloud | `CrealityCloud::SessionStore` (with its device uid) | `CrealityAccount` |
| Markforged Eiger | `Eiger::read_settings()` access and secret keys | `MarkforgedAccount` |

Model sites (Unlayered, MakerWorld, Nexprint, Thingiverse) keep their sign-ins in page cookies or
in accounts the phone has no client for, so they are not handed over.

Bambu's networking plugin does not expose its tokens. `BBLCloudServiceAgent::change_user` therefore
keeps the session the sign-in page reported in `<data_dir>/bambu_phone_session.bin`, sealed with
`SecretBox` in an owner-only file, and `user_logout` deletes it. The file is read once per run and
kept in memory, because the Accounts tab asks for the session every few seconds and each read would
open the keychain. A Bambu sign-in made before this file existed is listed as "not included" until
the person signs in again.

The phone holds the same tokens as the computer. A service that allows one live refresh token per
client may sign one side out when the other refreshes; signing in again on that side fixes it.

## Transfer

1. The dialog builds the payload `{"v":1,"computer":…,"accounts":[{"service":…},…]}` and starts a
   `PhoneSignIn::Server` on a free TCP port. The port listens on every IPv4 interface, but a
   connection is answered only when it arrives on one of the addresses in the QR code and comes
   from a private (RFC 1918), shared (RFC 6598) or link-local address.
2. The server seals the payload once with a fresh random 32-byte key: AES-256-GCM, 12-byte nonce,
   additional data `unified-signin-v1:<id>`, body `nonce || ciphertext || tag`.
3. The QR code holds `unifiedslicer://signin?v=1&h=<IPv4s>&p=<port>&i=<id>&k=<key>` (base64url
   id of 16 random bytes and key), with only this computer's private addresses, the only ones the
   phone accepts. The key exists only in the QR code and in memory.
4. The phone tries each address with `GET /signin/<id>` and decrypts the body. Any other request
   gets 404. A 128-bit id can't be guessed, so wrong requests never withdraw the offer: that would
   only let any device on the network cancel it.
5. After one complete delivery, after three minutes, or when the dialog closes, the server closes
   and the sealed copy is wiped. The dialog shows the address of the device that took the offer,
   so a delivery to a device other than the person's phone is visible.

The HTTP is plain because the payload is encrypted and authenticated with a key that never crosses
the network; a wrong id or a tampered body fails on the phone. Nothing is logged except the port.
The phone shows the accounts and saves them only after the person confirms. An account the phone
already has (same service and user) keeps its entry and gets the new tokens.

The phone and computer must be on the same local network. On Windows the first offer triggers the
firewall prompt; the dialog says to allow private networks.

The QR scheme is also an Android deep link, so the phone's camera app opens the same screen.
