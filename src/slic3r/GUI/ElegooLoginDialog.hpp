#pragma once

#include <functional>
#include <memory>
#include <string>

#include <wx/string.h>

#include "GUI_Utils.hpp"

class wxWebView;
class wxWebViewEvent;
class wxWindow;

namespace Slic3r { namespace GUI {

// Elegoo account sign-in. Hosts the Elegoo account site's slicer login page, which reports the
// tokens back over the WebView bridge ("report.userInfo"), and offers importing an ElegooSlicer
// sign-in instead.
class ElegooLoginDialog : public DPIDialog
{
public:
    explicit ElegooLoginDialog(wxWindow* parent);

    // Shows the dialog; true when an account is signed in afterwards.
    static bool sign_in(wxWindow* parent);

protected:
    void on_dpi_changed(const wxRect& suggested_rect) override;

private:
    void on_script_message(wxWebViewEvent& evt);
    void handle_script_message(wxWebViewEvent& evt);
    void respond(const wxString& id, const wxString& method, bool ok, const wxString& message);
    void load_page();
    // Runs `work`, which checks a sign-in with the cloud (up to half a minute), off the GUI thread;
    // `done` gets its result back on the GUI thread while the window is open. One at a time.
    void check_sign_in(std::function<bool(std::string& error)> work, std::function<void(bool ok, const std::string& error)> done);
    static std::string device_id();

    wxWebView*            m_browser{nullptr};
    bool                  m_checking{false};
    std::shared_ptr<bool> m_alive{std::make_shared<bool>(true)}; // expires with the window
};

}} // namespace Slic3r::GUI
