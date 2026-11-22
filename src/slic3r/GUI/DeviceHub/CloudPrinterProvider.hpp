#pragma once

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include <boost/filesystem/path.hpp>
#include <wx/colour.h>
#include <wx/string.h>

class wxWindow;

namespace Slic3r {
namespace GUI {
class CloudAccountSet;
}

class DynamicPrintConfig;

namespace GUI {

// One printer as a cloud service reports it, for the Device tab's lists.
struct CloudPrinter
{
    std::string provider_id; // CloudPrinterProvider::id() of the service that reported it
    std::string id;          // unique within the provider (serial number, device id)
    wxString    name;
    wxString    model;
    wxString    status;       // short, already translated ("Idle", "Printing", ...)
    bool        online{false};
    int         progress{-1}; // 0..100 while a job runs, -1 otherwise
    std::string image;        // picture for the card view: bitmap name in resources/images; empty for a generic one
    // The account it belongs to, for a service signed in to several (CloudAccountSet key); empty otherwise.
    std::string account_key;
    wxString    account_label;
};

// One account of a service signed in to several, for the Accounts tab and the Device tab's menu.
struct CloudAccountInfo
{
    std::string key;
    wxString    label;
    bool        active{false}; // the one sending, the Printer page and the service's model site use
};

// What the Plater hands a provider when the user prints to one of its printers.
struct CloudPrintRequest
{
    std::string             printer_id;  // empty: the provider asks the user to pick one
    boost::filesystem::path file;        // sliced .gcode or .gcode.3mf of the plate
    std::string             job_name;
    int                     plate_index{0};
};

// A printer cloud service shown as one button on the Device tab's service rail, with its own
// account. Built-in providers live next to this file; see docs/HLSD/device-hub.md.
//
// Everything here is called on the GUI thread, except the callback given to refresh_printers(),
// which may run on any thread (the caller marshals it back).
class CloudPrinterProvider
{
public:
    using PrintersCallback = std::function<void(std::vector<CloudPrinter> printers, wxString error)>;

    virtual ~CloudPrinterProvider() = default;

    // Stable key, also the rail button's name: "bbl", "elegoo", "creality", "markforged".
    virtual std::string id() const = 0;
    virtual wxString    display_name() const = 0;
    // Bitmap name from resources/images for the rail button; empty for text only.
    virtual std::string icon() const { return {}; }
    // Rail position, lowest first.
    virtual int order() const { return 100; }
    // Brand colour: the accent of the rail button and page while this service, or a printer of
    // it, is selected. Invalid for the app's default accent.
    virtual wxColour brand_colour() const { return {}; }

    // False while the service can't be used at all (e.g. its network plug-in isn't installed);
    // the page then shows unavailable_reason() and an install_or_enable() button.
    virtual bool     is_available() const { return true; }
    virtual wxString unavailable_reason() const { return {}; }
    virtual void     install_or_enable(wxWindow* /*parent*/) {}

    // Account. Each provider keeps its own login, independent of the others. A provider without
    // one (has_account() false) shows account_name() as the page's subtitle, and its primary
    // button runs login() as "Add printer".
    virtual bool     has_account() const { return true; }
    virtual bool     is_logged_in() const = 0;
    virtual wxString account_name() const { return {}; }
    virtual void     login(wxWindow* parent) = 0;
    virtual void     logout() = 0;

    // Several accounts at once. A provider that supports it creates m_account_set; login() and
    // logout() then act on the active account, and the user interface goes through these instead.
    bool                          supports_multiple_accounts() const { return m_account_set != nullptr; }
    // Every saved account; empty while signed out or for a provider with a single account.
    std::vector<CloudAccountInfo> accounts();
    // Signs in to one more account; the others stay signed in.
    void                          add_account(wxWindow* parent);
    // Makes a saved account the active one. False when its sign-in no longer works.
    bool                          switch_account(const std::string& key);
    // Signs out of one account, or of the active one when `key` is empty. Another saved account then
    // becomes active.
    void                          sign_out(const std::string& key = {});
    // Makes the account a printer belongs to active before printing to it or opening it; false when
    // that fails (the user is told).
    bool                          use_account_of(wxWindow* parent, const CloudPrinter& printer);

    // The printers bound to the account (and any found on the LAN).
    virtual void refresh_printers(PrintersCallback done) = 0;

    // Optional page of the provider's own, replacing the generic account + printer list page.
    // Owned by the parent once returned.
    virtual wxWindow* create_page(wxWindow* /*parent*/) { return nullptr; }

    // Double-click on a printer in a list: show its controls.
    virtual void open_printer(wxWindow* /*parent*/, const std::string& /*printer_id*/) {}

    // Printing. handles_printer_preset() picks the provider for the selected printer preset;
    // show_print_dialog() runs the provider's send dialog (printer, filament mapping, options).
    virtual bool handles_printer_preset(const DynamicPrintConfig& /*printer_config*/) const { return false; }
    virtual bool can_print() const { return false; }
    virtual void show_print_dialog(wxWindow* /*parent*/, const CloudPrintRequest& /*request*/) {}

protected:
    std::shared_ptr<CloudAccountSet> m_account_set;
};

using CloudPrinterProviderPtr = std::shared_ptr<CloudPrinterProvider>;

// Registry of the providers the Device tab shows.
class CloudPrinterProviders
{
public:
    using Listener = std::function<void(const std::string& provider_id)>;

    // Adds the built-in providers once; later calls do nothing.
    static void register_builtin();

    // Adds a provider, replacing one with the same id.
    static void add(CloudPrinterProviderPtr provider);
    static void remove(const std::string& id);

    // Sorted by order().
    static std::vector<CloudPrinterProviderPtr> all();
    static CloudPrinterProviderPtr              get(const std::string& id);
    // First provider whose handles_printer_preset() accepts the config, or null.
    static CloudPrinterProviderPtr for_printer_preset(const DynamicPrintConfig& printer_config);

    // A provider calls notify_changed() when its login state or printer list changed, from any
    // thread; listeners run on the GUI thread. An empty id means the provider list itself changed.
    static int  listen(Listener listener);
    static void unlisten(int handle);
    static void notify_changed(const std::string& provider_id);
};

}} // namespace Slic3r::GUI
