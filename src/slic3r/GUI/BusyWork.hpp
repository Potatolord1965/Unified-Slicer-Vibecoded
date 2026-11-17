#pragma once

#include <atomic>
#include <exception>
#include <functional>
#include <thread>

#include <wx/progdlg.h>
#include <wx/string.h>
#include <wx/utils.h>
#include <wx/window.h>

namespace Slic3r { namespace GUI {

// Runs a blocking call (a sign-in, a key check) on a worker thread and keeps the window painting
// behind a pulsing progress dialog until it returns, so a network timeout does not freeze the app.
// An exception from the call is rethrown here.
inline void run_busy(wxWindow *parent, const wxString &title, const wxString &message, const std::function<void()> &work)
{
    std::atomic<bool>  done{false};
    std::exception_ptr error;
    std::thread        worker([&] {
        try {
            work();
        } catch (...) {
            error = std::current_exception();
        }
        done = true;
    });
    {
        wxProgressDialog dlg(title, message, 100, parent, wxPD_APP_MODAL | wxPD_AUTO_HIDE);
        while (!done) {
            dlg.Pulse();
            wxMilliSleep(50);
        }
    }
    worker.join();
    if (error)
        std::rethrow_exception(error);
}

}} // namespace Slic3r::GUI
