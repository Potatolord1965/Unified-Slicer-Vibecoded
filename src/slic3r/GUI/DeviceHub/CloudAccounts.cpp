#include "CloudAccounts.hpp"

#include <algorithm>
#include <exception>
#include <iterator>
#include <set>
#include <thread>
#include <utility>

#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/fstream.hpp>

#include "libslic3r/Time.hpp"
#include "libslic3r/Utils.hpp"
#include "slic3r/Utils/SecretBox.hpp"

namespace Slic3r { namespace GUI {

namespace {

boost::filesystem::path accounts_file(const std::string& provider)
{
    return boost::filesystem::path(data_dir()) / "cloud_accounts" / (provider + ".bin");
}

std::string purpose(const std::string& provider) { return "cloud-accounts-" + provider; }

} // namespace

CloudAccountSet::CloudAccountSet(std::string provider_id, Hooks hooks) : m_provider(std::move(provider_id)), m_hooks(std::move(hooks)) {}

void CloudAccountSet::load_locked()
{
    if (m_loaded)
        return;
    m_loaded = true;
    try {
        boost::nowide::ifstream f(accounts_file(m_provider).string(), std::ios::binary);
        if (!f)
            return;
        const std::string    sealed((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        const nlohmann::json j = nlohmann::json::parse(SecretBox::open(sealed, purpose(m_provider)), nullptr, false);
        if (!j.is_array())
            return;
        for (const nlohmann::json& a : j) {
            if (!a.is_object() || !a.contains("key") || !a["key"].is_string() || a["key"].get<std::string>().empty())
                continue;
            SavedCloudAccount acc;
            acc.key   = a["key"].get<std::string>();
            acc.label = a.value("label", std::string());
            acc.data  = a.contains("data") ? a["data"] : nlohmann::json();
            m_accounts.push_back(std::move(acc));
        }
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "Cloud accounts: could not read the saved " << m_provider << " accounts: " << e.what();
    }
}

void CloudAccountSet::save_locked() const
{
    nlohmann::json j = nlohmann::json::array();
    for (const SavedCloudAccount& a : m_accounts)
        j.push_back({{"key", a.key}, {"label", a.label}, {"data", a.data}});
    try {
        const boost::filesystem::path path = accounts_file(m_provider);
        boost::filesystem::create_directories(path.parent_path());
        const std::string        sealed = SecretBox::seal(j.dump(), purpose(m_provider));
        boost::nowide::ofstream f(path.string(), std::ios::binary | std::ios::trunc);
        f.write(sealed.data(), static_cast<std::streamsize>(sealed.size()));
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(error) << "Cloud accounts: could not save the " << m_provider << " accounts: " << e.what();
    }
}

void CloudAccountSet::sync()
{
    const std::string key = m_hooks.active_key();
    if (key.empty())
        return;
    const std::string    label = m_hooks.active_label();
    const nlohmann::json data  = m_hooks.capture();

    std::lock_guard<std::mutex> lock(m_mutex);
    load_locked();
    auto it = std::find_if(m_accounts.begin(), m_accounts.end(), [&key](const SavedCloudAccount& a) { return a.key == key; });
    if (it == m_accounts.end()) {
        m_accounts.push_back({key, label, data});
        save_locked();
        return;
    }
    bool changed = false;
    if (!label.empty() && it->label != label) {
        it->label = label;
        changed   = true;
    }
    // Unknown sign-in data (a sign-in from before accounts were kept) never replaces known data.
    if (!data.is_null() && it->data != data) {
        it->data = data;
        changed  = true;
    }
    if (changed)
        save_locked();
}

std::vector<SavedCloudAccount> CloudAccountSet::accounts()
{
    sync();
    std::lock_guard<std::mutex> lock(m_mutex);
    load_locked();
    return m_accounts;
}

bool CloudAccountSet::switch_to(const std::string& key)
{
    sync();
    if (key == m_hooks.active_key())
        return true;
    SavedCloudAccount target;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        load_locked();
        auto it = std::find_if(m_accounts.begin(), m_accounts.end(), [&key](const SavedCloudAccount& a) { return a.key == key; });
        if (it == m_accounts.end() || it->data.is_null())
            return false;
        target = *it;
    }
    if (!m_hooks.active_key().empty())
        m_hooks.detach();
    const bool ok = m_hooks.apply(target.data) && m_hooks.active_key() == key;
    sync();
    return ok;
}

void CloudAccountSet::add(const std::function<void()>& login)
{
    sync();
    const std::string before = m_hooks.active_key();
    nlohmann::json    before_data;
    if (!before.empty()) {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            for (const SavedCloudAccount& a : m_accounts)
                if (a.key == before)
                    before_data = a.data;
        }
        m_hooks.detach();
    }
    login();
    // The sign-in windows are modal, so the sign-in has finished here. Cancelled: back to the
    // account that was in use.
    if (m_hooks.active_key().empty() && !before_data.is_null())
        m_hooks.apply(before_data);
    sync();
}

void CloudAccountSet::remove(const std::string& key, const std::function<void()>& sign_out)
{
    sync();
    const bool active = !key.empty() && key == m_hooks.active_key();
    if (active)
        sign_out();
    nlohmann::json next;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        load_locked();
        m_accounts.erase(std::remove_if(m_accounts.begin(), m_accounts.end(), [&key](const SavedCloudAccount& a) { return a.key == key; }),
                         m_accounts.end());
        save_locked();
        if (active)
            for (const SavedCloudAccount& a : m_accounts)
                if (!a.data.is_null()) {
                    next = a.data;
                    break;
                }
    }
    if (!next.is_null() && m_hooks.active_key().empty()) {
        m_hooks.apply(next);
        sync();
    }
}

void CloudAccountSet::update(const std::string& key, const nlohmann::json& data)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    load_locked();
    for (SavedCloudAccount& a : m_accounts)
        if (a.key == key && a.data != data) {
            a.data = data;
            save_locked();
        }
}

// ---------------------------------------------------------------------------------------------
// OtherAccountPrinters
// ---------------------------------------------------------------------------------------------

OtherAccountPrinters::OtherAccountPrinters(std::string provider_id, Fetch fetch) : m_provider(std::move(provider_id)), m_fetch(std::move(fetch)) {}

std::vector<CloudPrinter> OtherAccountPrinters::merge(std::vector<CloudPrinter>                active,
                                                      const std::shared_ptr<CloudAccountSet>& set,
                                                      wxString&                               error)
{
    if (!set)
        return active;
    const std::vector<SavedCloudAccount> accounts   = set->accounts();
    const std::string                    active_key = set->active_key();
    std::vector<SavedCloudAccount>       others;
    wxString                             active_label;
    for (const SavedCloudAccount& a : accounts) {
        if (a.key == active_key)
            active_label = wxString::FromUTF8(a.label.empty() ? a.key : a.label);
        else if (!a.data.is_null())
            others.push_back(a);
    }
    if (!active_key.empty())
        for (CloudPrinter& p : active) {
            p.account_key   = active_key;
            p.account_label = active_label;
        }

    const long long now = static_cast<long long>(Slic3r::Utils::get_current_time_utc());
    if (!others.empty() && now - m_last_fetch.load() >= 30 && !m_fetching.exchange(true)) {
        m_last_fetch = now;
        std::weak_ptr<OtherAccountPrinters> weak = shared_from_this();
        std::thread([weak, set, others]() {
            std::shared_ptr<OtherAccountPrinters> self = weak.lock();
            if (!self)
                return;
            std::vector<CloudPrinter> found;
            wxString                  errors;
            for (const SavedCloudAccount& a : others) {
                const wxString label = wxString::FromUTF8(a.label.empty() ? a.key : a.label);
                nlohmann::json data  = a.data;
                try {
                    for (CloudPrinter p : self->m_fetch(data)) {
                        p.provider_id   = self->m_provider;
                        p.account_key   = a.key;
                        p.account_label = label;
                        found.push_back(std::move(p));
                    }
                } catch (const std::exception& e) {
                    errors += (errors.empty() ? "" : "\n") + label + ": " + wxString::FromUTF8(e.what());
                }
                if (data != a.data)
                    set->update(a.key, data);
            }
            {
                std::lock_guard<std::mutex> lock(self->m_mutex);
                self->m_printers = std::move(found);
                self->m_error    = errors;
            }
            self->m_fetching = false;
            CloudPrinterProviders::notify_changed(self->m_provider);
        }).detach();
    }

    // Only accounts still saved and not active: after a switch the account fetched as "other" is
    // the active one and lists its printers itself.
    std::set<std::string> keys, ids;
    for (const SavedCloudAccount& a : others)
        keys.insert(a.key);
    for (const CloudPrinter& p : active)
        ids.insert(p.id);
    std::lock_guard<std::mutex> lock(m_mutex);
    for (const CloudPrinter& p : m_printers)
        if (keys.count(p.account_key) && ids.insert(p.id).second)
            active.push_back(p);
    if (!m_error.empty() && !others.empty())
        error = error.empty() ? m_error : error + "\n" + m_error;
    return active;
}

}} // namespace Slic3r::GUI
