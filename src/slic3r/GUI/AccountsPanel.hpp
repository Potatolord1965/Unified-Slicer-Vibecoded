#pragma once

#include <functional>
#include <string>
#include <vector>

#include <wx/colour.h>
#include <wx/scrolwin.h>
#include <wx/string.h>
#include <wx/timer.h>

class wxBoxSizer;
class wxStaticText;
class wxWindow;
class Button;

namespace Slic3r { namespace GUI {

// The Accounts tab: every account the app signs in to, in one list, each with its state and a
// Sign in / Sign out button. It holds no sign-in code of its own: printer services go through
// their CloudPrinterProvider (the Device tab's rail), the Unlayered account through ModelSiteView,
// and OrcaCloud through GUI_App. MakerWorld and Nexprint use the Bambu Lab and Elegoo accounts.
// See docs/HLSD/accounts-tab.md.
class AccountsPanel : public wxScrolledWindow
{
public:
    explicit AccountsPanel(wxWindow* parent);
    ~AccountsPanel() override;

    bool Show(bool show = true) override;
    void msw_rescale();
    void on_sys_color_changed();

private:
    struct Row
    {
        wxString name;
        wxString purpose;
        wxColour brand;
        // Null for a site without an account the app can see: the button then runs sign_in()
        // under action_label.
        std::function<bool()>          signed_in;
        std::function<wxString()>      account;
        std::function<void(wxWindow*)> sign_in;
        std::function<void()>          sign_out;
        wxString                       action_label;
        // Optional: false while the service can't be used; install() then offers to fix that.
        std::function<bool()>          available;
        std::function<wxString()>      unavailable_reason;
        std::function<void(wxWindow*)> install;
        // A service signed in to several accounts: while signed in the button adds one more.
        std::function<void(wxWindow*)> add_account;
        // Optional second button (an account's Sign out), and indentation for an account row.
        wxString                       secondary_label;
        std::function<void()>          secondary;
        bool                           indent{false};

        wxStaticText* status{nullptr};
        Button*       button{nullptr};
        Button*       second_button{nullptr};
        wxString      shown; // state last shown, so unchanged rows aren't relaid out
    };

    void rebuild();
    void add_section(const wxString& title);
    void add_row(Row row);
    void update_rows();
    void update_row(Row& row);
    // The saved accounts of every service signed in to several, as one string.
    std::string accounts_signature() const;

    wxBoxSizer*      m_list{nullptr};
    Button*          m_phone_button{nullptr};
    std::vector<Row> m_rows;
    std::string      m_accounts_shown; // the saved accounts the rows show, to rebuild when they change
    wxTimer          m_timer;
    int              m_listener{0};
    int              m_busy{0}; // a button's action is running
};

}} // namespace Slic3r::GUI
