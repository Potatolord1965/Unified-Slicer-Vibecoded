#include "PhoneSignInDialog.hpp"

#include <algorithm>
#include <chrono>
#include <string>
#include <utility>
#include <vector>

#include <wx/bitmap.h>
#include <wx/colour.h>
#include <wx/defs.h>
#include <wx/event.h>
#include <wx/gdicmn.h>
#include <wx/image.h>
#include <wx/sizer.h>
#include <wx/statbmp.h>
#include <wx/stattext.h>
#include <wx/string.h>
#include <wx/timer.h>
#include <wx/toplevel.h>
#include <wx/utils.h>

#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>
#include <qrcodegen.hpp>

#include "slic3r/GUI/GUI.hpp"
#include "slic3r/GUI/GUI_App.hpp"
#include "slic3r/GUI/GUI_Utils.hpp"
#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/format.hpp"
#include "slic3r/GUI/Widgets/Button.hpp"
#include "slic3r/GUI/Widgets/Label.hpp"
#include "slic3r/Utils/CloudProvider.hpp"
#include "slic3r/Utils/CrealityCloud.hpp"
#include "slic3r/Utils/ElegooCloud.hpp"
#include "slic3r/Utils/ICloudServiceAgent.hpp"
#include "slic3r/Utils/MarkforgedEiger.hpp"
#include "slic3r/Utils/NetworkAgent.hpp"
#include "slic3r/Utils/PhoneSignIn.hpp"
#include "libslic3r/AppConfig.hpp"

namespace Slic3r { namespace GUI {

using nlohmann::json;

namespace {

constexpr std::chrono::seconds CODE_LIFETIME{180};
constexpr int                  QR_SIZE_DIP = 240;

struct Offer
{
    json                  accounts = json::array();
    std::vector<wxString> included;
    std::vector<wxString> missing;
};

// The printer-service sign-ins this computer has, in the shape the phone app reads (one object per
// account, "service" naming it). Model sites sign in with cookies in their own pages, which stay here.
Offer collect()
{
    Offer o;

    if (wxGetApp().getAgent() != nullptr && wxGetApp().is_user_login(BBL_CLOUD_PROVIDER)) {
        std::string uid;
        if (auto cloud = wxGetApp().getAgent()->get_cloud_agent(BBL_CLOUD_PROVIDER))
            uid = cloud->get_user_id();
        const PhoneSignIn::BambuSession s = PhoneSignIn::bambu_session();
        if (!s.access_token.empty() && (uid.empty() || uid == s.user_id)) {
            const bool china = wxGetApp().app_config != nullptr && wxGetApp().app_config->get_country_code() == "CN";
            o.accounts.push_back({{"service", "bambu"},
                                  {"label", s.name.empty() ? std::string("Bambu Lab") : s.name},
                                  {"region", china ? "china" : "global"},
                                  {"access_token", s.access_token},
                                  {"refresh_token", s.refresh_token},
                                  {"user_id", s.user_id}});
            o.included.push_back("Bambu Lab");
        } else {
            // TRN Shown in the phone sign-in window for a Bambu Lab sign-in made before this feature existed.
            o.missing.push_back(_L("Bambu Lab: sign out and back in on this computer once, then make a new code."));
        }
    }

    ElegooCloud& elegoo = ElegooCloud::instance();
    if (elegoo.signed_in()) {
        const ElegooCloudAccount a = elegoo.account();
        o.accounts.push_back({{"service", "elegoo"},
                              {"label", elegoo.account_label()},
                              {"region", a.region},
                              {"access_token", a.access_token},
                              {"refresh_token", a.refresh_token},
                              {"access_expire_ms", a.access_expire_ms},
                              {"user_id", a.user_id}});
        o.included.push_back("Elegoo");
    }

    const CrealityCloud::Session creality = CrealityCloud::SessionStore::get();
    if (creality.valid()) {
        o.accounts.push_back({{"service", "creality"},
                              {"label", creality.nickname.empty() ? std::string("Creality Cloud") : creality.nickname},
                              {"region", creality.region == CrealityCloud::Region::China ? "china" : "global"},
                              {"token", creality.token},
                              {"user_id", creality.user_id},
                              {"device_uid", CrealityCloud::SessionStore::device_uid()}});
        o.included.push_back("Creality Cloud");
    }

    if (Eiger::has_keys()) {
        const json        s      = Eiger::read_settings();
        const std::string access = s.value("access_key", "");
        const std::string secret = s.value("secret_key", "");
        if (!access.empty() && !secret.empty()) {
            o.accounts.push_back({{"service", "markforged"}, {"label", "Markforged Eiger"}, {"access_key", access}, {"secret_key", secret}});
            o.included.push_back("Markforged Eiger");
        }
    }
    return o;
}

wxString join_lines(const std::vector<wxString>& lines)
{
    wxString out;
    for (const wxString& l : lines)
        out += (out.empty() ? "" : "\n") + l;
    return out;
}

} // namespace

PhoneSignInDialog::PhoneSignInDialog(wxWindow* parent)
    : DPIDialog(parent, wxID_ANY, _L("Sign in on your phone"), wxDefaultPosition, wxDefaultSize, wxCAPTION | wxCLOSE_BOX), m_timer(this)
{
    SetBackgroundColour(*wxWHITE);
    auto* sizer = new wxBoxSizer(wxVERTICAL);
    const int pad = FromDIP(20);

    auto* intro = new wxStaticText(this, wxID_ANY,
                                   _L("In the Unified Monitor app, open Accounts and tap \"Scan computer code\". "
                                      "Your phone must be on the same Wi-Fi as this computer."));
    intro->SetFont(Label::Body_13);
    intro->Wrap(FromDIP(360));
    sizer->Add(intro, 0, wxLEFT | wxRIGHT | wxTOP, pad);
#ifdef _WIN32
    auto* firewall = new wxStaticText(this, wxID_ANY, _L("If Windows asks, allow Unified Slicer on private networks."));
    firewall->SetFont(Label::Body_12);
    firewall->SetForegroundColour(wxColour("#6B6B6B"));
    firewall->Wrap(FromDIP(360));
    sizer->Add(firewall, 0, wxLEFT | wxRIGHT | wxTOP, FromDIP(6));
#endif

    m_qr = new wxStaticBitmap(this, wxID_ANY, wxNullBitmap, wxDefaultPosition, wxSize(FromDIP(QR_SIZE_DIP), FromDIP(QR_SIZE_DIP)));
    sizer->Add(m_qr, 0, wxALIGN_CENTER_HORIZONTAL | wxTOP | wxBOTTOM, pad);

    m_status = new wxStaticText(this, wxID_ANY, wxString(), wxDefaultPosition, wxDefaultSize, wxALIGN_CENTRE_HORIZONTAL);
    m_status->SetFont(Label::Head_13);
    sizer->Add(m_status, 0, wxEXPAND | wxLEFT | wxRIGHT, pad);

    m_included = new wxStaticText(this, wxID_ANY, wxString());
    m_included->SetFont(Label::Body_13);
    sizer->Add(m_included, 0, wxLEFT | wxRIGHT | wxTOP, pad);
    m_missing = new wxStaticText(this, wxID_ANY, wxString());
    m_missing->SetFont(Label::Body_12);
    m_missing->SetForegroundColour(wxColour("#6B6B6B"));
    sizer->Add(m_missing, 0, wxLEFT | wxRIGHT | wxTOP, FromDIP(6));

    auto* buttons = new wxBoxSizer(wxHORIZONTAL);
    buttons->AddStretchSpacer();
    m_new_code = new Button(this, _L("New code"));
    m_new_code->SetStyle(ButtonStyle::Regular, ButtonType::Choice);
    m_new_code->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) { new_code(); });
    buttons->Add(m_new_code, 0, wxRIGHT, FromDIP(8));
    auto* close = new Button(this, _L("Close"));
    close->SetStyle(ButtonStyle::Confirm, ButtonType::Choice);
    close->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) { EndModal(wxID_CLOSE); });
    buttons->Add(close, 0);
    sizer->Add(buttons, 0, wxEXPAND | wxALL, pad);

    Bind(wxEVT_TIMER, [this](wxTimerEvent&) { update_status(); }, m_timer.GetId());
    new_code();
    SetSizerAndFit(sizer);
    CenterOnParent();
    wxGetApp().UpdateDlgDarkUI(this);
}

PhoneSignInDialog::~PhoneSignInDialog()
{
    m_timer.Stop();
    m_server.stop();
}

void PhoneSignInDialog::new_code()
{
    m_server.stop();
    m_qr_text.clear();
    Offer offer    = collect();
    m_has_accounts = !offer.accounts.empty();
    // TRN Heading of the list of accounts the phone will be signed in to.
    m_included->SetLabel(offer.included.empty() ? _L("This computer isn't signed in to any printer service yet.") :
                                                  _L("Signs your phone in to:") + "\n" + join_lines(offer.included));
    m_missing->SetLabel(join_lines(offer.missing));
    m_missing->Show(!offer.missing.empty());

    if (!offer.accounts.empty()) {
        json        payload = {{"v", 1}, {"computer", into_u8(wxGetHostName())}, {"accounts", std::move(offer.accounts)}};
        std::string text    = payload.dump();
        std::string error;
        if (m_server.start(text, CODE_LIFETIME, error))
            m_qr_text = m_server.qr_text();
        else
            BOOST_LOG_TRIVIAL(warning) << "PhoneSignIn: could not offer sign-ins: " << error;
        std::fill(text.begin(), text.end(), '\0');
    }
    m_deadline = std::chrono::steady_clock::now() + CODE_LIFETIME;
    show_qr(m_qr_text);
    update_status();
    if (m_server.state() == PhoneSignIn::Server::State::Waiting)
        m_timer.Start(500);
    Layout();
    Fit();
}

void PhoneSignInDialog::update_status()
{
    using State = PhoneSignIn::Server::State;
    const State state = m_server.state();
    wxString    status;
    bool        done = true;
    switch (state) {
    case State::Waiting: {
        const auto left = std::max<long long>(0, std::chrono::duration_cast<std::chrono::seconds>(m_deadline - std::chrono::steady_clock::now()).count());
        // TRN %1% is minutes, %2% seconds (two digits) until the QR code expires.
        status = format_wxstr(_L("Waiting for your phone. Code expires in %1%:%2%"), left / 60, wxString::Format("%02lld", left % 60));
        done   = false;
        break;
    }
    case State::Delivered:
        // TRN %1% is the network address of the device that fetched the sign-ins, e.g. "192.168.1.23".
        status = format_wxstr(_L("Sent to the device at %1%. Your phone is signing in."), m_server.delivered_to());
        break;
    case State::Expired: status = _L("This code expired. Make a new one to try again."); break;
    case State::Failed: status = _L("This code stopped working. Make a new one."); break;
    case State::Idle:
        if (m_has_accounts)
            status = _L("Couldn't share on the network. Check that this computer is on Wi-Fi or Ethernet.");
        break;
    }
    if (done) {
        m_timer.Stop();
        if (state != State::Waiting && m_qr->GetBitmap().IsOk())
            show_qr({});
    }
    m_new_code->Show(done && state != State::Delivered);
    if (m_status->GetLabel() != status) {
        m_status->SetLabel(status);
        Layout();
    }
}

void PhoneSignInDialog::show_qr(const std::string& text)
{
    const int side = FromDIP(QR_SIZE_DIP);
    if (text.empty()) {
        m_qr->SetBitmap(wxNullBitmap);
        m_qr->SetMinSize(wxSize(side, side));
        m_qr->Hide();
        return;
    }
    const qrcodegen::QrCode qr = qrcodegen::QrCode::encodeText(text.c_str(), qrcodegen::QrCode::Ecc::MEDIUM);
    // Dark modules on white with the standard four-module quiet zone, in light and dark mode alike:
    // phone scanners expect that contrast.
    const int modules = qr.getSize() + 8;
    const int scale   = std::max(1, side / modules);
    const int px      = modules * scale;
    wxImage   img(px, px);
    img.SetRGB(wxRect(0, 0, px, px), 255, 255, 255);
    for (int y = 0; y < qr.getSize(); ++y)
        for (int x = 0; x < qr.getSize(); ++x)
            if (qr.getModule(x, y))
                img.SetRGB(wxRect((x + 4) * scale, (y + 4) * scale, scale, scale), 0, 0, 0);
    m_qr->SetBitmap(wxBitmap(img));
    m_qr->SetMinSize(wxSize(px, px));
    m_qr->Show();
}

void PhoneSignInDialog::on_dpi_changed(const wxRect&)
{
    show_qr(m_server.state() == PhoneSignIn::Server::State::Waiting ? m_qr_text : std::string());
    Layout();
    Fit();
}

}} // namespace Slic3r::GUI
