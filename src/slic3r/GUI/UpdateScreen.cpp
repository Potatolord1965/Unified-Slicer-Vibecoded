#include "UpdateScreen.hpp"

#include <string>
#include <wx/checkbox.h> // IWYU pragma: keep
#include <wx/gauge.h> // IWYU pragma: keep
#include <wx/sizer.h>
#include <wx/stattext.h> // IWYU pragma: keep
#include <wx/textctrl.h>
#include <wx/utils.h>

#include "GUI_Utils.hpp"
#include "libslic3r_version.h"
#include "GUI_App.hpp"
#include "I18N.hpp"
#include "UnifiedUpdater.hpp"
#include "Widgets/Button.hpp"
#include "Widgets/Label.hpp"
#include "wx/event.h"
#include "wx/gdicmn.h"
#include "wx/toplevel.h"
#include "wx/stringimpl.h"

namespace Slic3r { namespace GUI {

UpdateScreen::UpdateScreen(wxWindow* parent)
    : DPIDialog(parent, wxID_ANY, _L("Updates"), wxDefaultPosition, wxDefaultSize, wxCAPTION | wxCLOSE_BOX | wxRESIZE_BORDER)
{
    SetBackgroundColour(*wxWHITE);
    const int gap = FromDIP(10);

    auto* main = new wxBoxSizer(wxVERTICAL);

    m_headline = new wxStaticText(this, wxID_ANY, wxEmptyString);
    m_headline->SetFont(Label::Head_16);
    main->Add(m_headline, 0, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, gap * 2);

    m_status = new wxStaticText(this, wxID_ANY, wxEmptyString);
    main->Add(m_status, 0, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, gap * 2);

    m_gauge = new wxGauge(this, wxID_ANY, 1000, wxDefaultPosition, wxSize(-1, FromDIP(6)));
    main->Add(m_gauge, 0, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, gap * 2);

    m_notes = new wxTextCtrl(this, wxID_ANY, wxEmptyString, wxDefaultPosition, FromDIP(wxSize(560, 300)),
                             wxTE_MULTILINE | wxTE_READONLY | wxTE_RICH2 | wxBORDER_SIMPLE);
    main->Add(m_notes, 1, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, gap * 2);

    m_auto = new wxCheckBox(this, wxID_ANY, _L("Download updates automatically and install them when Unified Slicer closes"));
    m_auto->SetValue(UnifiedUpdater::auto_install_enabled());
    m_auto->Bind(wxEVT_CHECKBOX, [this](wxCommandEvent&) {
        UnifiedUpdater::set_auto_install(m_auto->GetValue());
        if (m_auto->GetValue() && UnifiedUpdater::instance().state() == UnifiedUpdater::State::Available)
            UnifiedUpdater::instance().download();
    });
    main->Add(m_auto, 0, wxEXPAND | wxLEFT | wxRIGHT | wxTOP, gap * 2);

    auto make_button = [this](const wxString& label, ButtonStyle style) {
        auto* b = new Button(this, label);
        b->SetStyle(style, ButtonType::Choice);
        return b;
    };
    m_check    = make_button(_L("Check again"), ButtonStyle::Regular);
    m_page     = make_button(_L("Release page"), ButtonStyle::Regular);
    m_download = make_button(_L("Download"), ButtonStyle::Regular);
    m_restart  = make_button(_L("Restart and update"), ButtonStyle::Confirm);

    m_check->Bind(wxEVT_BUTTON, [](wxCommandEvent&) { UnifiedUpdater::instance().check(); });
    m_page->Bind(wxEVT_BUTTON, [](wxCommandEvent&) {
        const std::string url = UnifiedUpdater::instance().release().page_url;
        if (!url.empty())
            wxLaunchDefaultBrowser(wxString::FromUTF8(url));
    });
    m_download->Bind(wxEVT_BUTTON, [](wxCommandEvent&) { UnifiedUpdater::instance().download(); });
    m_restart->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        EndModal(wxID_OK);
        UnifiedUpdater::instance().restart_and_install();
    });

    auto* buttons = new wxBoxSizer(wxHORIZONTAL);
    buttons->Add(m_check, 0, wxRIGHT, gap);
    buttons->Add(m_page, 0, wxRIGHT, gap);
    buttons->AddStretchSpacer();
    buttons->Add(m_download, 0, wxLEFT, gap);
    buttons->Add(m_restart, 0, wxLEFT, gap);
    main->Add(buttons, 0, wxEXPAND | wxALL, gap * 2);

    m_listener = UnifiedUpdater::instance().add_listener([this]() { refresh(); });
    refresh();

    SetSizerAndFit(main);
    CenterOnParent();
    wxGetApp().UpdateDlgDarkUI(this);
}

UpdateScreen::~UpdateScreen() { UnifiedUpdater::instance().remove_listener(m_listener); }

void UpdateScreen::show(wxWindow* parent)
{
    auto& updater = UnifiedUpdater::instance();
    const auto state = updater.state();
    if (state == UnifiedUpdater::State::Idle || state == UnifiedUpdater::State::UpToDate || state == UnifiedUpdater::State::Failed)
        updater.check();
    UpdateScreen dlg(parent);
    dlg.ShowModal();
}

void UpdateScreen::refresh()
{
    using State         = UnifiedUpdater::State;
    auto&         u     = UnifiedUpdater::instance();
    const State   state = u.state();
    const auto    rel   = u.release();
    const wxString mine = wxString::FromUTF8(UnifiedUpdater::current_version());
    const wxString next = wxString::FromUTF8(rel.version);
    const bool     have_release = state == State::Available || state == State::Downloading || state == State::Ready ||
                              (state == State::Failed && !rel.version.empty());

    if (have_release)
        m_headline->SetLabel(wxString::Format(_L("Unified Slicer %s is available"), next));
    else if (state == State::Checking)
        m_headline->SetLabel(_L("Checking for updates..."));
    else
        m_headline->SetLabel(_L("Unified Slicer is up to date"));

    wxString status = wxString::Format(_L("Installed version: %s (OrcaSlicer %s)"), mine, wxString::FromUTF8(SoftFever_VERSION));
    switch (state) {
    case State::Downloading:
        status += "\n" + wxString::Format(_L("Downloading the update: %d%%"), int(u.progress() * 100.));
        break;
    case State::Ready:
        status += "\n" + (UnifiedUpdater::auto_install_enabled() ?
                              _L("The update is downloaded. It installs when you close Unified Slicer, or restart now.") :
                              _L("The update is downloaded. Restart to install it."));
        break;
    case State::Available:
        if (!u.can_install())
            status += "\n" + _L("This release can't be installed from inside the app. Download it from the release page.");
        break;
    case State::Failed: status += "\n" + wxString::FromUTF8(u.error()); break;
    default: break;
    }
    const std::string last = u.last_install_error();
    if (!last.empty())
        status += "\n" + wxString::Format(_L("The last update could not be installed: %s"), wxString::FromUTF8(last));
    m_status->SetLabel(status);
    m_status->Wrap(FromDIP(560));

    m_gauge->Show(state == State::Downloading || state == State::Ready);
    m_gauge->SetValue(state == State::Ready ? 1000 : int(u.progress() * 1000.));

    m_notes->Show(have_release);
    if (have_release && m_notes->GetValue() != wxString::FromUTF8(rel.notes))
        m_notes->SetValue(wxString::FromUTF8(rel.notes.empty() ? _u8L("No release notes.") : rel.notes));

    m_check->Enable(state != State::Checking && state != State::Downloading);
    m_page->Show(have_release && !rel.page_url.empty());
    m_download->Show((state == State::Available || state == State::Failed) && have_release && u.can_install());
    m_restart->Show(state == State::Ready);

    Layout();
    Fit();
}

void UpdateScreen::on_dpi_changed(const wxRect&)
{
    for (Button* b : {m_check, m_page, m_download, m_restart})
        b->Rescale();
    Layout();
    Fit();
    Refresh();
}

}} // namespace Slic3r::GUI
