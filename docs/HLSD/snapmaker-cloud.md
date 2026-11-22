# Snapmaker cloud printing

Prints to a Snapmaker U1 that is bound to the user's Snapmaker ID, over the internet, through Snapmaker's own cloud service. The app acts as the slicer client Snapmaker's service already serves: it signs in to Snapmaker ID, uploads the G-code to Snapmaker's storage and sends the printer the same print command Snapmaker Orca sends. Snapmaker's servers deliver the job; nothing of the service is reimplemented. LAN printing to the same printer is the usual print host from the printer preset.

## Parts

| Part | Role |
| --- | --- |
| `Utils/SnapmakerMqtt.{hpp,cpp}` | A minimal MQTT 3.1.1 client over TLS with a client certificate (Boost.Asio and OpenSSL, no extra library). Blocking with deadlines; used from worker threads. |
| `Utils/SnapmakerCloud.{hpp,cpp}` | REST client, pure helpers (reply parsers, request bodies, checksums, topic names, the print request), the session store and `PrinterLink`, one broker connection to one printer. Unit tested in `tests/slic3rutils/test_snapmaker_cloud.cpp`. |
| `Utils/SnapmakerCloudServiceAgent` | `ICloudServiceAgent` for provider `snapmaker`. Signs in and out only. |
| `Utils/SnapmakerCloudPrinterAgent` | `IPrinterAgent` with id `snapmaker_cloud`. Lists the account's printers, polls the connected one with `printer.objects.query`, uploads and starts prints, and maps pause, resume, stop, G-code and temperature commands to Moonraker methods. |
| `GUI/VendorSendBackends.cpp` (`SnapmakerBackend`, `SnapmakerCloudHost`) | The native send dialog for U1 presets: the LAN printer from the preset plus the account's printers. Other Snapmaker printers keep the standard send dialog. |
| `GUI/WebUserLoginDialog.cpp` | Captures the Snapmaker ID token in the shared login window. |

## Session

Sign-in opens `https://id.snapmaker.com?from=orca` (`id.snapmaker.cn` for China) in the shared login window. Snapmaker ID hands the token back in the URL it redirects to (`token=`) or as the body of its `/api/oauth2/callback/` page (`{"data":{"access_token":...}}`), never through a script message, so the window watches navigations, page loads and, every 500 ms, its current URL. On the callback page it copies the body into the document title, which the window reads. The token then goes through the same `user_login` path as other providers; `change_user()` validates it against `/api/common/accounts/current` and stores the account.

`SnapmakerCloud::SessionStore` keeps the session in `<data_dir>/snapmaker_cloud.json`, sealed with `SecretBox`. The token is sent as the raw `Authorization` header and has no refresh flow: a 401 means signing in again. The token is never handed to a web page.

## Protocol

Taken from Snapmaker Orca 2.4 (AGPL-3.0) and the web pages it ships. REST calls go to `https://api.snapmaker.com/api` (`api.snapmaker.cn` for China) with the client headers Snapmaker Orca sends, and answer with a `{code, msg, data}` envelope where 200 or 0 is success.

1. **Devices.** `POST /user/device/list` returns the account's printers: `id` (used by uploads), `sn` (the broker topic prefix), name, product name, firmware version and online state.
2. **Upload.** `POST /user/device/upload/create` with the file name, its base64 SHA-256 and the device id returns a presigned `PUT` URL. Files over 5 MiB are split into 5 MiB parts, each with its own checksum and URL; the ETag of each part goes back in `/user/device/upload/completed`, which returns the download URL. A failed multipart upload is cancelled with `/user/device/upload/cancel`.
3. **Broker.** `GET /user/device/getMqttCert` returns an AWS IoT Core endpoint, a client id, a client certificate and key, and the topic templates. The broker's certificate chains to Amazon Root CA 1, which is embedded.
4. **Start.** A Moonraker JSON-RPC request published on `<sn>/request`: `server.files.start_cloud_print {type, url, auto_start, checksum, size}`, or `server.files.pull` on firmware before 1.3.0 and for a send without printing. The printer answers on `<sn>/response` with the same id and downloads the file itself.

## Constraints

- AWS IoT allows one connection per client id, and the account has one. The printer agent keeps a single shared link; a send from the dialog opens its own, which can drop the agent's link until its next poll reconnects.
- Camera, filament mapping and print options are not offered for cloud printers.
- The protocol has not been tested against a live printer.
