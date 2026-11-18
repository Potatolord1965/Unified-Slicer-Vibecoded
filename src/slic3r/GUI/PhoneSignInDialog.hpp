#pragma once

#include <chrono>
#include <string>

#include <wx/timer.h>

#include "GUI_Utils.hpp"
#include "slic3r/Utils/PhoneSignIn.hpp"

class wxBoxSizer;
class wxStaticBitmap;
class wxStaticText;
class wxWindow;
class Button;

namespace Slic3r { namespace GUI {

// Shows a QR code the Unified Monitor phone app scans to sign in to the same printer-service
// accounts as this computer (Bambu Lab, Elegoo, Creality, Markforged). The sign-ins go to the
// phone once, encrypted with a key that is only in the QR code. See docs/HLSD/phone-sign-in.md.
class PhoneSignInDialog : public DPIDialog
{
public:
    explicit PhoneSignInDialog(wxWindow* parent);
    ~PhoneSignInDialog() override;

protected:
    void on_dpi_changed(const wxRect& suggested_rect) override;

private:
    void new_code();
    void update_status();
    void show_qr(const std::string& text);

    PhoneSignIn::Server                   m_server;
    std::chrono::steady_clock::time_point m_deadline;
    wxTimer                               m_timer;
    wxStaticBitmap*                       m_qr{nullptr};
    wxStaticText*                         m_included{nullptr};
    wxStaticText*                         m_missing{nullptr};
    wxStaticText*                         m_status{nullptr};
    Button*                               m_new_code{nullptr};
    std::string                           m_qr_text;
    bool                                  m_has_accounts{false};
};

}} // namespace Slic3r::GUI
