#include "CloudPrinterProvider.hpp"
#include "CloudAccounts.hpp"

#include <algorithm>
#include <map>
#include <mutex>
#include <utility>

#include <wx/app.h>
#include <wx/defs.h>

#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/MsgDialog.hpp"
#include "slic3r/GUI/format.hpp"

namespace Slic3r { namespace GUI {

namespace {

std::mutex                           s_mutex;
std::vector<CloudPrinterProviderPtr> s_providers;
std::map<int, CloudPrinterProviders::Listener> s_listeners;
int                                  s_next_listener{1};

} // namespace

std::vector<CloudAccountInfo> CloudPrinterProvider::accounts()
{
    std::vector<CloudAccountInfo> out;
    if (!m_account_set)
        return out;
    const std::string active = m_account_set->active_key();
    for (const SavedCloudAccount& a : m_account_set->accounts())
        out.push_back({a.key, wxString::FromUTF8(a.label.empty() ? a.key : a.label), a.key == active});
    return out;
}

void CloudPrinterProvider::add_account(wxWindow* parent)
{
    if (m_account_set)
        m_account_set->add([this, parent] { login(parent); });
    else
        login(parent);
    CloudPrinterProviders::notify_changed(id());
}

bool CloudPrinterProvider::switch_account(const std::string& key)
{
    const bool ok = m_account_set && m_account_set->switch_to(key);
    CloudPrinterProviders::notify_changed(id());
    return ok;
}

void CloudPrinterProvider::sign_out(const std::string& key)
{
    if (!m_account_set)
        logout();
    else
        m_account_set->remove(key.empty() ? m_account_set->active_key() : key, [this] { logout(); });
    CloudPrinterProviders::notify_changed(id());
}

bool CloudPrinterProvider::use_account_of(wxWindow* parent, const CloudPrinter& printer)
{
    if (!m_account_set || printer.account_key.empty() || printer.account_key == m_account_set->active_key())
        return true;
    if (switch_account(printer.account_key))
        return true;
    // TRN %1% is an account name, %2% a printer service such as "Bambu Lab".
    MessageDialog(parent,
                  format_wxstr(_L("The sign-in of %1% no longer works. Sign in to that %2% account again on the Accounts tab."),
                               printer.account_label, display_name()),
                  display_name(), wxOK | wxICON_WARNING)
        .ShowModal();
    return false;
}

void CloudPrinterProviders::add(CloudPrinterProviderPtr provider)
{
    if (!provider)
        return;
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        const std::string id = provider->id();
        s_providers.erase(std::remove_if(s_providers.begin(), s_providers.end(),
                                         [&id](const CloudPrinterProviderPtr& p) { return p->id() == id; }),
                          s_providers.end());
        s_providers.push_back(std::move(provider));
        std::stable_sort(s_providers.begin(), s_providers.end(),
                         [](const CloudPrinterProviderPtr& a, const CloudPrinterProviderPtr& b) { return a->order() < b->order(); });
    }
    notify_changed({});
}

void CloudPrinterProviders::remove(const std::string& id)
{
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        s_providers.erase(std::remove_if(s_providers.begin(), s_providers.end(),
                                         [&id](const CloudPrinterProviderPtr& p) { return p->id() == id; }),
                          s_providers.end());
    }
    notify_changed({});
}

std::vector<CloudPrinterProviderPtr> CloudPrinterProviders::all()
{
    std::lock_guard<std::mutex> lock(s_mutex);
    return s_providers;
}

CloudPrinterProviderPtr CloudPrinterProviders::get(const std::string& id)
{
    std::lock_guard<std::mutex> lock(s_mutex);
    for (const CloudPrinterProviderPtr& p : s_providers)
        if (p->id() == id)
            return p;
    return nullptr;
}

CloudPrinterProviderPtr CloudPrinterProviders::for_printer_preset(const DynamicPrintConfig& printer_config)
{
    for (const CloudPrinterProviderPtr& p : all())
        if (p->handles_printer_preset(printer_config))
            return p;
    return nullptr;
}

int CloudPrinterProviders::listen(Listener listener)
{
    std::lock_guard<std::mutex> lock(s_mutex);
    const int handle = s_next_listener++;
    s_listeners.emplace(handle, std::move(listener));
    return handle;
}

void CloudPrinterProviders::unlisten(int handle)
{
    std::lock_guard<std::mutex> lock(s_mutex);
    s_listeners.erase(handle);
}

void CloudPrinterProviders::notify_changed(const std::string& provider_id)
{
    if (wxTheApp == nullptr)
        return;
    // Listeners are looked up when the call runs, so one removed in between is not called.
    wxTheApp->CallAfter([provider_id] {
        std::vector<Listener> listeners;
        {
            std::lock_guard<std::mutex> lock(s_mutex);
            for (const auto& [handle, listener] : s_listeners)
                listeners.push_back(listener);
        }
        for (const Listener& listener : listeners)
            listener(provider_id);
    });
}

}} // namespace Slic3r::GUI
