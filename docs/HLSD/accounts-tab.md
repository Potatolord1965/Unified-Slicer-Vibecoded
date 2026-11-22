# Accounts tab

The **Accounts** tab (`src/slic3r/GUI/AccountsPanel.{hpp,cpp}`, last of the built-in main tabs)
lists every account the app signs in to, with its state ("Signed in as …", "Not signed in") and a
Sign in / Sign out button. It has no sign-in code of its own; each row calls the code that already
owns that account, so signing in here and signing in from the Device tab or a Home model site are
the same action.

| Section | Row | Account code |
|---|---|---|
| Printer services | One row per `CloudPrinterProvider` with `has_account()` (Bambu Lab, Elegoo, Creality, Markforged, and any later provider) | The provider's `is_logged_in()`, `account_name()`, `login()`, `logout()`; `is_available()` false shows the reason and an Install button (`install_or_enable()`) |
| Model sites | Unlayered Universe | `ModelSiteView::unlayered_signed_in()` / `unlayered_sign_out()` (device token in the OS credential store). Sign in opens Universe on the Home tab and starts the device hand-off there (`unlayered_start_sign_in()`), since the signed-in page is shown in that view |
| | MakerWorld, Nexprint | The Bambu Lab and Elegoo providers: both sites sign in with those accounts, as in Bambu Studio and ElegooSlicer |
| | Thingiverse | None the app can see: the site keeps its sign-in in its own page cookies. The row's button opens the site on the Home tab |
| Slicer | OrcaCloud | `GUI_App::is_user_login` / `request_login` / `request_user_logout` with the Orca provider |

## Several accounts of one service

Bambu Lab, Elegoo, Creality and Markforged can each be signed in to several accounts at once. Each
service's own code works with one account at a time, the **active** one: sending from the Plater, the
Printer page and the service's model site (MakerWorld, Nexprint) use it. The others stay signed in:

- `CloudAccountSet` (`DeviceHub/CloudAccounts.{hpp,cpp}`) keeps every account the service was signed
  in to, with what it takes to sign in to it again (tokens, API keys), sealed with `SecretBox` in
  `<data_dir>/cloud_accounts/<provider id>.bin`. It learns the active account from the service on
  every look (`sync()`), so a sign-in anywhere in the app is kept, and refreshed tokens are saved.
- A provider gives the set five hooks: the active account's key and name, its sign-in data, how to
  make saved data the active sign-in, and a local sign-out that leaves the session valid on the
  server (so the account can be switched back to). Bambu's plug-in keeps its tokens to itself, so its
  sign-in data is the `user_login` message its page reported (`PhoneSignIn` keeps it), replayed with
  `change_user`.
- `OtherAccountPrinters` lists the printers of the accounts that are not active, each with its own
  token, on a worker thread at most every 30 s; a token the service rejects is refreshed once and the
  new one saved. The Device tab shows them next to the active account's, with an Account column.
- Opening one of those printers, or picking an account in a send dialog's **Switch account** link,
  makes its account active first (`CloudPrinterProvider::use_account_of` / `switch_account`).

On this tab a service signed in to two or more accounts has a row per account under its own row: the
active one says so, the others have **Use**, and each has **Sign out**. The service's own button
becomes **Add account**, which sets the active account aside, runs the sign-in, and goes back to it
when the sign-in is cancelled. Signing out of the active account makes the next saved one active. On
the Device tab the service page's **Accounts** button offers the same in a menu.

Sign-ins finish in their own windows, so while the tab is shown it re-reads every row every two
seconds, and also when a provider calls `CloudPrinterProviders::notify_changed`. A row is relaid out
only when its state changed, and the rows are rebuilt when the saved accounts change (never while a
row's button is still running its sign-in window). A change to the provider list rebuilds the rows.

The brand colour of each printer service (`brand_colour()`) marks its row and colours its Sign in
button, the same accent the Device tab's rail uses.

**Sign in on phone** in the tab's header shows a QR code that signs the Unified Monitor phone app in to
the same printer services; see [phone-sign-in.md](phone-sign-in.md).
