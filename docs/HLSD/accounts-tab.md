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

Sign-ins finish in their own windows, so while the tab is shown it re-reads every row every two
seconds, and also when a provider calls `CloudPrinterProviders::notify_changed`. A row is relaid out
only when its state changed. A change to the provider list rebuilds the rows.

The brand colour of each printer service (`brand_colour()`) marks its row and colours its Sign in
button, the same accent the Device tab's rail uses.
