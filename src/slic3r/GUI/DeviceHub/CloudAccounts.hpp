#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>
#include <wx/string.h>

#include "CloudPrinterProvider.hpp"

namespace Slic3r { namespace GUI {

// One account of a printer service that the app keeps signed in.
struct SavedCloudAccount
{
    std::string    key;   // the service's user id (or API key), unique within the service
    std::string    label; // name to show, UTF-8
    nlohmann::json data;  // what the service needs to use this account again (tokens, keys); null when unknown
};

// Several accounts of one printer service. The service's own code works with one signed-in account
// at a time, the active one: sending, the Printer page, MakerWorld and Nexprint use it. The others
// are kept here, so the Device tab can list their printers with their own tokens and the user can
// switch to them without signing in again. Kept sealed (SecretBox) in
// <data_dir>/cloud_accounts/<provider id>.bin. See docs/HLSD/accounts-tab.md.
//
// Thread safe: background printer fetches write refreshed tokens back with update().
class CloudAccountSet
{
public:
    struct Hooks
    {
        std::function<std::string()>               active_key;   // empty while signed out
        std::function<std::string()>               active_label;
        std::function<nlohmann::json()>            capture;      // the active account's sign-in; null when unknown
        std::function<bool(const nlohmann::json&)> apply;        // makes a saved account the active one
        std::function<void()>                      detach;       // local sign-out that leaves the session valid
    };

    CloudAccountSet(std::string provider_id, Hooks hooks);

    // Saves the active account (a new sign-in, refreshed tokens). Writes only when something changed.
    void                           sync();
    // Every account, the active one included, after a sync().
    std::vector<SavedCloudAccount> accounts();
    std::string                    active_key() const { return m_hooks.active_key(); }
    // False when the account is unknown or its saved sign-in no longer works.
    bool                           switch_to(const std::string& key);
    // Signs in to one more account: the active one is set aside (still saved) while `login` runs the
    // service's sign-in. When that ends without a new sign-in, the account set aside is active again.
    void                           add(const std::function<void()>& login);
    // Forgets an account. For the active one `sign_out` runs the service's own sign-out, then the next
    // saved account becomes active.
    void                           remove(const std::string& key, const std::function<void()>& sign_out);
    // New sign-in data for a saved account that is not active (tokens a background fetch refreshed).
    // Written only while the saved data is still `before`, what the fetch started from: a sign-in
    // saved in the meantime (the user signed in again, or switched to the account) is newer.
    void                           update(const std::string& key, const nlohmann::json& before, const nlohmann::json& data);

private:
    // The saved accounts merged into m_accounts (an account already there keeps its entry).
    // False when the file exists but can't be read now, e.g. while the keychain is locked.
    bool read_locked();
    void load_locked();
    void save_locked();

    std::string                    m_provider;
    Hooks                          m_hooks;
    mutable std::mutex             m_mutex;
    bool                           m_loaded{false};
    // The file couldn't be read: it is not written over until it has been read, so the accounts in it
    // aren't lost to a keychain that was locked once.
    bool                           m_unread{false};
    std::vector<SavedCloudAccount> m_accounts;
};

// The printers of a service's saved accounts besides the active one, each listed with its own
// sign-in on a worker thread, at most every 30 s.
class OtherAccountPrinters : public std::enable_shared_from_this<OtherAccountPrinters>
{
public:
    // Lists one account's printers. May change `data` (refreshed tokens), which is then saved.
    // Blocking; throws std::exception with a message for the user.
    using Fetch = std::function<std::vector<CloudPrinter>(nlohmann::json& data)>;

    OtherAccountPrinters(std::string provider_id, Fetch fetch);

    // The active account's printers (tagged with it) followed by the other accounts' printers known
    // now. Starts a fetch when one is due; the provider is notified when it ends. `error` gets the
    // accounts whose printers could not be listed. A printer two accounts share is listed once.
    std::vector<CloudPrinter> merge(std::vector<CloudPrinter> active, const std::shared_ptr<CloudAccountSet>& set, wxString& error);
    // Fetches again on the next merge(), e.g. after the active account changed.
    void                      invalidate() { m_last_fetch = 0; }

private:
    std::string               m_provider;
    Fetch                     m_fetch;
    std::mutex                m_mutex;
    std::vector<CloudPrinter> m_printers; // guarded by m_mutex
    wxString                  m_error;    // guarded by m_mutex
    std::atomic<long long>    m_last_fetch{0};
    std::atomic<bool>         m_fetching{false};
};

}} // namespace Slic3r::GUI
