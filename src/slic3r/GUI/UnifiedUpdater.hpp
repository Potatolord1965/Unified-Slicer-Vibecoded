#pragma once

#include <cstddef>
#include <functional>
#include <map>
#include <mutex>
#include <string>

namespace Slic3r { namespace GUI {

// Keeps Unified Slicer up to date from this project's own GitHub releases.
//
// Every engine change (OrcaSlicer, the Elegoo, Creality, Bambu and Unlayered code) reaches users
// as a Unified Slicer release, so the app only has to follow one feed: the latest release of
// UNIFIED_UPDATE_REPO. A release is offered when its tag (vX.Y.Z) is newer than UNIFIED_VERSION.
//
// Nothing pops up. The top bar shows an update button while a release is available, and the
// button opens UpdateScreen. With automatic updates on (the default) the package is downloaded in
// the background and installed when the app closes, or straight away from "Restart and update".
//
// Installing is Windows only: the release must carry UnifiedSlicer-<version>-win64.zip, its .sha256
// file and that file's Ed25519 signature (.sha256.sig) by the key in UpdateSignature. The zip is
// checked against the signed hash, then a helper waits for the app to exit and runs
// resources/updater/apply_update.ps1, with administrator rights only when the install folder is
// not writable. See docs/HLSD/updater.md.
class UnifiedUpdater
{
public:
    enum class State { Idle, Checking, UpToDate, Available, Downloading, Ready, Failed };

    struct Release
    {
        std::string version;     // "1.2.0"
        std::string notes;       // release body, Markdown
        std::string page_url;    // release page on GitHub
        std::string zip_url;     // Windows package, empty when the release has none
        std::string zip_name;
        std::string sha256_url;
        std::string sig_url;     // signature of the .sha256 file
        size_t      zip_size{0};
    };

    static UnifiedUpdater& instance();

    // Asks GitHub for the latest release. Downloads it straight away when automatic updates are on.
    void check();
    // Downloads and verifies the package of the available release.
    void download();
    // True when this build can install a package itself (Windows, with a signed package in the release).
    bool can_install() const;
    // Marks the downloaded package to be installed with a restart, then closes the main window.
    // The install itself starts from install_pending() once the app has shut down.
    void restart_and_install();
    // Called from GUI_App::OnExit(): starts the install helper when a verified package is ready.
    void install_pending();

    State       state() const;
    Release     release() const;
    std::string error() const;
    // Download progress in 0..1.
    double      progress() const;
    // What the last install attempt wrote to its log, when it failed; empty otherwise.
    std::string last_install_error() const;
    // True when Windows was refused administrator rights for this release's package, which then
    // only installs from "Restart and update".
    bool        install_declined() const;

    static bool auto_install_enabled();
    static void set_auto_install(bool enable);
    static std::string current_version();

    // Listeners run on the GUI thread whenever the state or the progress changes.
    int  add_listener(std::function<void()> fn);
    void remove_listener(int id);

private:
    UnifiedUpdater();
    void set_state(State state, const std::string& error = {});
    void notify();
    std::string updates_dir() const;
    std::string package_path() const;
    void        read_last_install_log();
    // Downloads a small release asset (checksum, signature) and passes its body to `then`.
    void        fetch_asset(const std::string& url, std::function<void(std::string)> then);
    void        download_verified(const Release& rel, const std::string& checksum, const std::string& signature);

    mutable std::mutex                    m_mutex;
    State                                 m_state{State::Idle};
    Release                               m_release;
    std::string                           m_error;
    std::string                           m_sha256;
    std::string                           m_last_install_error;
    // The package whose install was refused administrator rights, so it isn't offered at every exit.
    std::string                           m_declined_package;
    double                                m_progress{0.};
    bool                                  m_restart_after_install{false};
    int                                   m_next_listener{1};
    std::map<int, std::function<void()>> m_listeners;
};

}} // namespace Slic3r::GUI
