#pragma once

#include "GUI_Utils.hpp"

class wxCheckBox;
class wxGauge;
class wxStaticText;
class wxTextCtrl;
class wxWindow;
class Button;

namespace Slic3r { namespace GUI {

// The update screen opened from the top bar's update button and from Help > Check for Updates.
// Shows the state of UnifiedUpdater, the release notes and the install actions.
class UpdateScreen : public DPIDialog
{
public:
    explicit UpdateScreen(wxWindow* parent);
    ~UpdateScreen() override;

    // Opens the screen and starts a check when none has run yet.
    static void show(wxWindow* parent);

protected:
    void on_dpi_changed(const wxRect& suggested_rect) override;

private:
    void refresh();

    int           m_listener{0};
    wxStaticText* m_headline{nullptr};
    wxStaticText* m_status{nullptr};
    wxGauge*      m_gauge{nullptr};
    wxTextCtrl*   m_notes{nullptr};
    wxCheckBox*   m_auto{nullptr};
    Button*       m_check{nullptr};
    Button*       m_page{nullptr};
    Button*       m_download{nullptr};
    Button*       m_restart{nullptr};
};

}} // namespace Slic3r::GUI
