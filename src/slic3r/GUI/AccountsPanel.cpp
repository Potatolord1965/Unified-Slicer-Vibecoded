#include "AccountsPanel.hpp"

#include <map>
#include <memory>
#include <utility>

#include <wx/defs.h>
#include <wx/event.h>
#include <wx/panel.h>
#include <wx/sizer.h>
#include <wx/stattext.h>

#include "slic3r/GUI/DeviceHub/CloudPrinterProvider.hpp"
#include "slic3r/GUI/DeviceHub/DeviceHubPanel.hpp"
#include "slic3r/GUI/GUI.hpp"
#include "slic3r/GUI/GUI_App.hpp"
#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/MainFrame.hpp"
#include "slic3r/GUI/ModelSiteView.hpp"
#include "slic3r/GUI/PhoneSignInDialog.hpp"
#include "slic3r/GUI/WebViewDialog.hpp"
#include "slic3r/GUI/format.hpp"
#include "slic3r/GUI/Widgets/Button.hpp"
#include "slic3r/GUI/Widgets/Label.hpp"
#include "slic3r/Utils/CloudProvider.hpp"
#include "slic3r/Utils/NetworkAgent.hpp"

namespace Slic3r { namespace GUI {

namespace {

constexpr int REFRESH_INTERVAL_MS = 2000;

// Opens `site` on the Home tab's model-site pane and returns its view.
ModelSiteView* show_model_site(const std::string& site)
{
    wxGetApp().mainframe->select_tab(wxString(TAB_ID_HOME));
    WebViewPanel* home = WebViewPanel::ensure();
    if (home == nullptr)
        return nullptr;
    home->set_model_site(site);
    return home->model_view(site, false);
}

// What each printer service's account is used for, by provider id.
wxString provider_purpose(const std::string& id)
{
    static const std::map<std::string, std::string> purposes = {
        {"bbl", L("Bambu Lab printers and MakerWorld")},
        {"elegoo", L("Elegoo printers and Nexprint")},
        {"creality", L("Creality Cloud printers")},
        {"markforged", L("Markforged printers (Eiger)")},
    };
    const auto it = purposes.find(id);
    return it != purposes.end() ? _(it->second) : _L("Printers");
}

wxString orca_account_name()
{
    NetworkAgent* agent = wxGetApp().getAgent();
    if (agent == nullptr)
        return {};
    std::shared_ptr<ICloudServiceAgent> cloud = agent->get_cloud_agent(ORCA_CLOUD_PROVIDER);
    if (!cloud || !cloud->is_user_login())
        return {};
    std::string name = cloud->get_user_nickname();
    if (name.empty())
        name = cloud->get_user_name();
    return from_u8(name);
}

} // namespace

AccountsPanel::AccountsPanel(wxWindow* parent)
    : wxScrolledWindow(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize, wxVSCROLL), m_timer(this)
{
    SetBackgroundColour(*wxWHITE);
    SetScrollRate(0, FromDIP(10));
    CloudPrinterProviders::register_builtin();

    auto* outer = new wxBoxSizer(wxVERTICAL);
    auto* header = new wxBoxSizer(wxHORIZONTAL);
    auto* title  = new wxStaticText(this, wxID_ANY, _L("Accounts"));
    title->SetFont(Label::Head_18);
    header->Add(title, 0, wxALIGN_CENTER_VERTICAL);
    header->AddStretchSpacer();
    // Signs the Unified Monitor phone app in to the same printer services with one QR scan.
    m_phone_button = new Button(this, _L("Sign in on phone"));
    m_phone_button->SetMinSize(wxSize(FromDIP(100), -1));
    m_phone_button->SetStyle(ButtonStyle::Regular, ButtonType::Window);
    m_phone_button->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        PhoneSignInDialog dlg(this);
        dlg.ShowModal();
    });
    header->Add(m_phone_button, 0, wxALIGN_CENTER_VERTICAL);
    outer->Add(header, 0, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, FromDIP(24));
    auto* intro = new wxStaticText(this, wxID_ANY, _L("Every account Unified Slicer signs in to. Each one is separate: signing out of one leaves the others signed in."));
    intro->SetFont(Label::Body_13);
    intro->SetForegroundColour(wxColour("#6B6B6B"));
    outer->Add(intro, 0, wxLEFT | wxRIGHT | wxTOP, FromDIP(6));

    m_list = new wxBoxSizer(wxVERTICAL);
    outer->Add(m_list, 0, wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM, FromDIP(24));
    SetSizer(outer);

    Bind(wxEVT_TIMER, [this](wxTimerEvent&) { update_rows(); }, m_timer.GetId());
    m_listener = CloudPrinterProviders::listen([this](const std::string& provider_id) {
        if (provider_id.empty())
            rebuild();
        else
            update_rows();
    });
    rebuild();
}

AccountsPanel::~AccountsPanel() { CloudPrinterProviders::unlisten(m_listener); }

bool AccountsPanel::Show(bool show)
{
    const bool changed = wxScrolledWindow::Show(show);
    // Sign-ins finish in their own windows, so the list follows them while it is in view.
    if (show) {
        update_rows();
        m_timer.Start(REFRESH_INTERVAL_MS);
    } else {
        m_timer.Stop();
    }
    return changed;
}

void AccountsPanel::rebuild()
{
    Freeze();
    m_list->Clear(true);
    m_rows.clear();

    add_section(_L("Printer services"));
    for (const CloudPrinterProviderPtr& p : CloudPrinterProviders::all()) {
        if (!p->has_account())
            continue;
        std::weak_ptr<CloudPrinterProvider> wp = p;
        Row row;
        row.name               = p->display_name();
        row.purpose            = provider_purpose(p->id());
        row.brand              = p->brand_colour();
        row.signed_in          = [wp] { auto s = wp.lock(); return s && s->is_logged_in(); };
        row.account            = [wp] { auto s = wp.lock(); return s ? s->account_name() : wxString(); };
        row.sign_in            = [wp](wxWindow* parent) { if (auto s = wp.lock()) s->login(parent); };
        row.sign_out           = [wp] { if (auto s = wp.lock()) s->logout(); };
        row.available          = [wp] { auto s = wp.lock(); return s && s->is_available(); };
        row.unavailable_reason = [wp] { auto s = wp.lock(); return s ? s->unavailable_reason() : wxString(); };
        row.install            = [wp](wxWindow* parent) { if (auto s = wp.lock()) s->install_or_enable(parent); };
        add_row(std::move(row));
    }

    add_section(_L("Model sites"));
    {
        Row row;
        row.name      = "Unlayered Universe";
        row.purpose   = _L("Unlayered account, for Universe on the Home tab");
        row.signed_in = [] { return ModelSiteView::unlayered_signed_in(); };
        row.sign_in   = [](wxWindow*) {
            if (ModelSiteView* view = show_model_site("unlayered"))
                view->unlayered_start_sign_in();
        };
        row.sign_out = [] {
            ModelSiteView::unlayered_sign_out();
            if (WebViewPanel* home = WebViewPanel::if_built())
                if (ModelSiteView* view = home->model_view("unlayered", false); view != nullptr && view->loaded())
                    view->load_home();
        };
        add_row(std::move(row));
    }
    // MakerWorld and Nexprint sign in with the printer service's account, as in their own slicers.
    const std::pair<const char*, const char*> shared[] = {{"MakerWorld", "bbl"}, {"Nexprint", "elegoo"}};
    for (const auto& [site, provider_id] : shared) {
        CloudPrinterProviderPtr p = CloudPrinterProviders::get(provider_id);
        if (!p)
            continue;
        std::weak_ptr<CloudPrinterProvider> wp = p;
        Row row;
        row.name = site;
        // TRN %1% is a printer brand whose account a model site signs in with, e.g. "Bambu Lab".
        row.purpose            = format_wxstr(_L("Uses your %1% account"), p->display_name());
        row.brand              = p->brand_colour();
        row.signed_in          = [wp] { auto s = wp.lock(); return s && s->is_logged_in(); };
        row.account            = [wp] { auto s = wp.lock(); return s ? s->account_name() : wxString(); };
        row.sign_in            = [wp](wxWindow* parent) { if (auto s = wp.lock()) s->login(parent); };
        row.sign_out           = [wp] { if (auto s = wp.lock()) s->logout(); };
        row.available          = [wp] { auto s = wp.lock(); return s && s->is_available(); };
        row.unavailable_reason = [wp] { auto s = wp.lock(); return s ? s->unavailable_reason() : wxString(); };
        row.install            = [wp](wxWindow* parent) { if (auto s = wp.lock()) s->install_or_enable(parent); };
        add_row(std::move(row));
    }
    {
        Row row;
        row.name         = "Thingiverse";
        row.purpose      = _L("Signs in on its own page on the Home tab");
        row.action_label = _L("Open");
        row.sign_in      = [](wxWindow*) { show_model_site("thingiverse"); };
        add_row(std::move(row));
    }

    add_section(_L("Slicer"));
    {
        Row row;
        row.name      = "OrcaCloud";
        row.purpose   = _L("Sync of your own presets");
        row.signed_in = [] { return wxGetApp().getAgent() != nullptr && wxGetApp().is_user_login(ORCA_CLOUD_PROVIDER); };
        row.account   = [] { return orca_account_name(); };
        row.sign_in   = [](wxWindow*) { wxGetApp().request_login(true, ORCA_CLOUD_PROVIDER); };
        row.sign_out  = [] { wxGetApp().request_user_logout(ORCA_CLOUD_PROVIDER, true); };
        row.available = [] { return wxGetApp().getAgent() != nullptr; };
        row.unavailable_reason = [] { return _L("Not available while the app's network features are off."); };
        add_row(std::move(row));
    }

    update_rows();
    FitInside();
    Layout();
    Thaw();
}

void AccountsPanel::add_section(const wxString& title)
{
    auto* label = new wxStaticText(this, wxID_ANY, title);
    label->SetFont(Label::Head_14);
    m_list->Add(label, 0, wxTOP | wxBOTTOM, FromDIP(8));
    m_list->AddSpacer(FromDIP(4));
}

void AccountsPanel::add_row(Row row)
{
    const size_t index = m_rows.size();

    auto* line = new wxBoxSizer(wxHORIZONTAL);
    // Brand swatch; the app's grey for accounts without a brand colour.
    auto* swatch = new wxPanel(this, wxID_ANY, wxDefaultPosition, wxSize(FromDIP(4), FromDIP(36)));
    swatch->SetBackgroundColour(row.brand.IsOk() ? row.brand : wxColour("#9E9E9E"));
    line->Add(swatch, 0, wxALIGN_CENTER_VERTICAL | wxRIGHT, FromDIP(12));

    auto* names = new wxBoxSizer(wxVERTICAL);
    auto* name  = new wxStaticText(this, wxID_ANY, row.name);
    name->SetFont(Label::Head_13);
    auto* purpose = new wxStaticText(this, wxID_ANY, row.purpose);
    purpose->SetFont(Label::Body_12);
    purpose->SetForegroundColour(wxColour("#6B6B6B"));
    names->Add(name, 0, wxBOTTOM, FromDIP(2));
    names->Add(purpose, 0);
    names->SetMinSize(wxSize(FromDIP(300), -1));
    line->Add(names, 0, wxALIGN_CENTER_VERTICAL);

    row.status = new wxStaticText(this, wxID_ANY, wxEmptyString, wxDefaultPosition, wxSize(FromDIP(260), -1), wxST_ELLIPSIZE_END);
    row.status->SetFont(Label::Body_13);
    line->Add(row.status, 0, wxALIGN_CENTER_VERTICAL | wxLEFT, FromDIP(16));
    line->AddStretchSpacer();

    row.button = new Button(this, row.action_label.empty() ? _L("Sign in") : row.action_label);
    row.button->SetMinSize(wxSize(FromDIP(100), -1));
    row.button->Bind(wxEVT_BUTTON, [this, index](wxCommandEvent&) {
        if (index >= m_rows.size())
            return;
        Row& r = m_rows[index];
        if (r.available && !r.available()) {
            if (r.install)
                r.install(this);
        } else if (r.signed_in && r.signed_in()) {
            if (r.sign_out)
                r.sign_out();
        } else if (r.sign_in) {
            r.sign_in(this);
        }
        // The rows may have been rebuilt meanwhile (a provider list change).
        CallAfter([this] { update_rows(); });
    });
    line->Add(row.button, 0, wxALIGN_CENTER_VERTICAL | wxLEFT, FromDIP(16));

    m_list->Add(line, 0, wxEXPAND | wxTOP | wxBOTTOM, FromDIP(8));
    m_rows.push_back(std::move(row));
}

void AccountsPanel::update_rows()
{
    bool changed = false;
    for (Row& row : m_rows) {
        const wxString before = row.shown;
        update_row(row);
        changed |= row.shown != before;
    }
    if (changed)
        Layout();
}

void AccountsPanel::update_row(Row& row)
{
    wxString status, label;
    bool     primary;
    if (row.available && !row.available()) {
        status  = row.unavailable_reason ? row.unavailable_reason() : _L("Not available");
        label   = _L("Install");
        primary = true;
        if (!row.install)
            label.clear();
    } else if (!row.signed_in) {
        status  = wxEmptyString;
        label   = row.action_label;
        primary = false;
    } else if (row.signed_in()) {
        const wxString name = row.account ? row.account() : wxString();
        // TRN %1% is the name of a signed-in account.
        status  = name.empty() ? _L("Signed in") : format_wxstr(_L("Signed in as %1%"), name);
        label   = _L("Sign out");
        primary = false;
    } else {
        status  = _L("Not signed in");
        label   = _L("Sign in");
        primary = true;
    }

    const wxString shown = status + "\n" + label + (primary ? "1" : "0");
    if (shown == row.shown)
        return;
    row.shown = shown;

    row.status->SetLabel(status);
    row.status->SetToolTip(status);
    row.button->Show(!label.empty());
    row.button->SetLabel(label);
    if (primary)
        style_primary(row.button, ButtonType::Window, row.brand);
    else
        row.button->SetStyle(ButtonStyle::Regular, ButtonType::Window);
}

void AccountsPanel::msw_rescale()
{
    m_phone_button->SetMinSize(wxSize(FromDIP(100), -1));
    m_phone_button->Rescale();
    for (Row& row : m_rows) {
        row.button->SetMinSize(wxSize(FromDIP(100), -1));
        row.button->Rescale();
    }
    Layout();
}

void AccountsPanel::on_sys_color_changed()
{
    for (Row& row : m_rows)
        row.shown.clear();
    update_rows();
    Refresh();
}

}} // namespace Slic3r::GUI
