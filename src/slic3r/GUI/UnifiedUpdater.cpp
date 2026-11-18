#include "UnifiedUpdater.hpp"

#include <algorithm>
#include <boost/optional/optional.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <cctype>
#include <cstddef>
#include <exception>
#include <ios>
#include <functional>
#include <openssl/ossl_typ.h> // IWYU pragma: keep
#include <mutex>
#include <sstream>
#include <string>
#include <stdexcept>
#include <utility>
#include <vector>

#include <boost/algorithm/string/predicate.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/fstream.hpp>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <wx/app.h>

#include "libslic3r/AppConfig.hpp"
#include "libslic3r/Semver.hpp"
#include "libslic3r/Utils.hpp"
#include "libslic3r_version.h"
#include "slic3r/Utils/Http.hpp"
#include "GUI.hpp"
#include "GUI_App.hpp"
#include "I18N.hpp"
#include "MainFrame.hpp"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <wx/stdpaths.h>
#endif

namespace fs = boost::filesystem;

namespace Slic3r { namespace GUI {

namespace {

// The GitHub repository whose releases this build follows.
constexpr const char* UNIFIED_UPDATE_REPO   = "Potatolord1965/Unified-Slicer-Vibecoded";
constexpr const char* AUTO_INSTALL_KEY      = "auto_install_updates";
constexpr const char* INSTALL_LOG_NAME      = "apply_update.log";
constexpr const char* INSTALL_SCRIPT_NAME   = "apply_update.ps1";
constexpr size_t      MAX_PACKAGE_SIZE      = size_t(2) * 1024 * 1024 * 1024 - 1;

// Copies the package over the install folder once the app has exited. Kept as a script so that
// the files of the running executable are no longer locked when they are replaced.
constexpr const char* INSTALL_SCRIPT = R"PS(param([int]$WaitPid, [string]$Zip, [string]$Dest, [string]$Exe, [string]$Restart)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $Zip
$log = Join-Path $dir 'apply_update.log'
function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format s) + ' ' + $m) }
Set-Content -Path $log -Value ((Get-Date -Format s) + ' starting')
try {
    try { Wait-Process -Id $WaitPid -Timeout 120 -ErrorAction SilentlyContinue } catch {}
    $stage = Join-Path $dir 'staging'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -Path $Zip -DestinationPath $stage -Force
    $exeName = Split-Path -Leaf $Exe
    $src = $stage
    if (-not (Test-Path (Join-Path $src $exeName))) {
        $dirs = @(Get-ChildItem $src -Directory)
        if ($dirs.Count -eq 1 -and (Test-Path (Join-Path $dirs[0].FullName $exeName))) { $src = $dirs[0].FullName }
        else { throw "the package has no $exeName" }
    }
    robocopy $src $Dest /E /R:15 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copying the files failed (robocopy $LASTEXITCODE)" }
    Remove-Item $stage -Recurse -Force
    Remove-Item $Zip -Force
    Log 'installed'
} catch {
    Log ('failed: ' + $_)
}
if ($Restart -eq '1') { Start-Process -FilePath $Exe }
)PS";

std::string sha256_of_file(const fs::path& path)
{
    boost::nowide::ifstream in(path.string(), std::ios::binary);
    if (!in)
        return {};
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr);
    std::vector<char> buf(1 << 20);
    while (in) {
        in.read(buf.data(), std::streamsize(buf.size()));
        if (in.gcount() > 0)
            EVP_DigestUpdate(ctx, buf.data(), size_t(in.gcount()));
    }
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int  len = 0;
    EVP_DigestFinal_ex(ctx, digest, &len);
    EVP_MD_CTX_free(ctx);
    static const char* hex = "0123456789abcdef";
    std::string        out;
    for (unsigned int i = 0; i < len; ++i) {
        out.push_back(hex[digest[i] >> 4]);
        out.push_back(hex[digest[i] & 0xf]);
    }
    return out;
}

// A .sha256 file holds the hex digest, optionally followed by the file name.
std::string parse_sha256_file(const std::string& body)
{
    std::istringstream ss(body);
    std::string        digest;
    ss >> digest;
    std::transform(digest.begin(), digest.end(), digest.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    if (digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](char c) { return std::isxdigit((unsigned char) c); }))
        return {};
    return digest;
}

boost::optional<Semver> parse_tag(std::string tag)
{
    if (!tag.empty() && (tag.front() == 'v' || tag.front() == 'V'))
        tag.erase(0, 1);
    return Semver::parse(tag);
}

} // namespace

UnifiedUpdater& UnifiedUpdater::instance()
{
    static UnifiedUpdater updater;
    return updater;
}

UnifiedUpdater::UnifiedUpdater() { read_last_install_log(); }

std::string UnifiedUpdater::current_version() { return UNIFIED_VERSION; }

bool UnifiedUpdater::auto_install_enabled()
{
    AppConfig* cfg = wxGetApp().app_config;
    return cfg == nullptr || cfg->get(AUTO_INSTALL_KEY).empty() || cfg->get_bool(AUTO_INSTALL_KEY);
}

void UnifiedUpdater::set_auto_install(bool enable)
{
    if (AppConfig* cfg = wxGetApp().app_config)
        cfg->set_bool(AUTO_INSTALL_KEY, enable);
}

std::string UnifiedUpdater::updates_dir() const { return (fs::path(data_dir()) / "updates").string(); }

std::string UnifiedUpdater::package_path() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_release.zip_name.empty() ? std::string() : (fs::path(updates_dir()) / m_release.zip_name).string();
}

void UnifiedUpdater::read_last_install_log()
{
    try {
        const fs::path log = fs::path(updates_dir()) / INSTALL_LOG_NAME;
        if (!fs::exists(log))
            return;
        boost::nowide::ifstream in(log.string());
        std::string             line, last;
        while (std::getline(in, line))
            if (!line.empty())
                last = line;
        if (last.find(" failed: ") != std::string::npos)
            m_last_install_error = last.substr(last.find(" failed: ") + 9);
    } catch (const std::exception&) {}
}

UnifiedUpdater::State UnifiedUpdater::state() const { std::lock_guard<std::mutex> lock(m_mutex); return m_state; }
UnifiedUpdater::Release UnifiedUpdater::release() const { std::lock_guard<std::mutex> lock(m_mutex); return m_release; }
std::string UnifiedUpdater::error() const { std::lock_guard<std::mutex> lock(m_mutex); return m_error; }
double UnifiedUpdater::progress() const { std::lock_guard<std::mutex> lock(m_mutex); return m_progress; }
std::string UnifiedUpdater::last_install_error() const { std::lock_guard<std::mutex> lock(m_mutex); return m_last_install_error; }

bool UnifiedUpdater::can_install() const
{
#ifdef _WIN32
    std::lock_guard<std::mutex> lock(m_mutex);
    return !m_release.zip_url.empty() && !m_release.sha256_url.empty();
#else
    return false;
#endif
}

int UnifiedUpdater::add_listener(std::function<void()> fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_listeners[m_next_listener] = std::move(fn);
    return m_next_listener++;
}

void UnifiedUpdater::remove_listener(int id)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_listeners.erase(id);
}

void UnifiedUpdater::set_state(State state, const std::string& error)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_state = state;
        m_error = error;
    }
    if (!error.empty())
        BOOST_LOG_TRIVIAL(warning) << "Updater: " << error;
    notify();
}

void UnifiedUpdater::notify()
{
    // Requests finish on worker threads, possibly while the app is shutting down.
    if (wxTheApp == nullptr)
        return;
    wxTheApp->CallAfter([this]() {
        std::vector<std::function<void()>> listeners;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            for (auto& [id, fn] : m_listeners)
                listeners.push_back(fn);
        }
        for (auto& fn : listeners)
            fn();
    });
}

void UnifiedUpdater::check()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state == State::Checking || m_state == State::Downloading || m_state == State::Ready)
            return;
    }
    set_state(State::Checking);

    const std::string url = std::string("https://api.github.com/repos/") + UNIFIED_UPDATE_REPO + "/releases/latest";
    Http::get(url)
        .header("Accept", "application/vnd.github+json")
        .timeout_connect(10)
        .timeout_max(30)
        .on_error([this](std::string, std::string error, unsigned status) {
            // 404: the repository has no published release yet.
            if (status == 404)
                set_state(State::UpToDate);
            else
                set_state(State::Failed, _u8L("Could not reach GitHub:") + " " + (error.empty() ? "HTTP " + std::to_string(status) : error));
        })
        .on_complete([this](std::string body, unsigned) {
            try {
                const auto json = nlohmann::json::parse(body);
                const auto tag  = parse_tag(json.value("tag_name", ""));
                const auto mine = Semver::parse(current_version());
                if (!tag || !mine || !(*mine < *tag) || json.value("draft", false) || json.value("prerelease", false)) {
                    set_state(State::UpToDate);
                    return;
                }
                Release rel;
                rel.version  = tag->to_string_sf();
                rel.notes    = json.value("body", "");
                rel.page_url = json.value("html_url", "");
                for (const auto& asset : json.value("assets", nlohmann::json::array())) {
                    const std::string name = asset.value("name", "");
                    const std::string link = asset.value("browser_download_url", "");
                    if (boost::istarts_with(name, "UnifiedSlicer-") && boost::iends_with(name, "-win64.zip")) {
                        rel.zip_name = name;
                        rel.zip_url  = link;
                        rel.zip_size = asset.value("size", size_t(0));
                    }
                }
                for (const auto& asset : json.value("assets", nlohmann::json::array()))
                    if (!rel.zip_name.empty() && asset.value("name", "") == rel.zip_name + ".sha256")
                        rel.sha256_url = asset.value("browser_download_url", "");
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    m_release  = rel;
                    m_progress = 0.;
                }
                set_state(State::Available);
                if (auto_install_enabled() && can_install())
                    download();
            } catch (const std::exception& e) {
                set_state(State::Failed, _u8L("Unexpected answer from GitHub:") + " " + e.what());
            }
        })
        .perform();
}

void UnifiedUpdater::download()
{
    if (!can_install())
        return;
    Release rel;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state != State::Available && m_state != State::Failed)
            return;
        rel = m_release;
    }
    set_state(State::Downloading);

    // The hash first: it decides whether a package left over from an earlier session can be used.
    Http::get(rel.sha256_url)
        .timeout_connect(10)
        .timeout_max(60)
        .on_error([this](std::string, std::string error, unsigned status) {
            set_state(State::Failed, _u8L("Could not download the update checksum:") + " " + (error.empty() ? "HTTP " + std::to_string(status) : error));
        })
        .on_complete([this, rel](std::string body, unsigned) {
            const std::string digest = parse_sha256_file(body);
            if (digest.empty()) {
                set_state(State::Failed, _u8L("The update checksum file is not valid."));
                return;
            }
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_sha256 = digest;
            }
            const fs::path target = fs::path(updates_dir()) / rel.zip_name;
            try {
                fs::create_directories(target.parent_path());
                if (fs::exists(target) && sha256_of_file(target) == digest) {
                    set_state(State::Ready);
                    return;
                }
            } catch (const std::exception& e) {
                set_state(State::Failed, _u8L("Could not prepare the update folder:") + " " + e.what());
                return;
            }

            Http::get(rel.zip_url)
                .size_limit(MAX_PACKAGE_SIZE)
                .timeout_connect(15)
                .on_progress([this](Http::Progress p, bool&) {
                    if (p.dltotal == 0)
                        return;
                    const double now = double(p.dlnow) / double(p.dltotal);
                    bool         changed;
                    {
                        std::lock_guard<std::mutex> lock(m_mutex);
                        changed    = now - m_progress >= 0.01 || now >= 1.;
                        if (changed)
                            m_progress = now;
                    }
                    if (changed)
                        notify();
                })
                .on_error([this](std::string, std::string error, unsigned status) {
                    set_state(State::Failed, _u8L("Could not download the update:") + " " + (error.empty() ? "HTTP " + std::to_string(status) : error));
                })
                .on_complete([this, target, digest](std::string body, unsigned) {
                    try {
                        const fs::path partial = target.string() + ".part";
                        {
                            boost::nowide::ofstream out(partial.string(), std::ios::binary | std::ios::trunc);
                            out.write(body.data(), std::streamsize(body.size()));
                            if (!out)
                                throw std::runtime_error("could not write " + partial.string());
                        }
                        body.clear();
                        if (sha256_of_file(partial) != digest) {
                            fs::remove(partial);
                            set_state(State::Failed, _u8L("The downloaded update does not match its checksum."));
                            return;
                        }
                        fs::rename(partial, target);
                        set_state(State::Ready);
                    } catch (const std::exception& e) {
                        set_state(State::Failed, _u8L("Could not save the update:") + " " + e.what());
                    }
                })
                .perform();
        })
        .perform();
}

void UnifiedUpdater::restart_and_install()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state != State::Ready)
            return;
        m_restart_after_install = true;
    }
    // Closing goes through the usual "save project?" questions; if the user cancels, the package
    // is still installed when the app is closed later, only without the restart.
    if (MainFrame* frame = wxGetApp().mainframe)
        frame->Close();
}

void UnifiedUpdater::install_pending()
{
#ifdef _WIN32
    bool        restart;
    std::string digest;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state != State::Ready)
            return;
        restart = m_restart_after_install;
        digest  = m_sha256;
    }
    if (!restart && !auto_install_enabled())
        return;
    try {
        const fs::path zip = package_path();
        // Checked again: the file sat in the user's data folder since it was downloaded.
        if (zip.empty() || sha256_of_file(zip) != digest) {
            BOOST_LOG_TRIVIAL(error) << "Updater: package missing or changed, not installing";
            return;
        }
        const fs::path script = zip.parent_path() / INSTALL_SCRIPT_NAME;
        {
            boost::nowide::ofstream out(script.string(), std::ios::trunc);
            out << INSTALL_SCRIPT;
        }
        const fs::path exe  = fs::path(into_u8(wxStandardPaths::Get().GetExecutablePath()));
        const fs::path dest = exe.parent_path();

        // An install under Program Files needs administrator rights for the copy.
        bool writable = false;
        try {
            const fs::path probe = dest / ".unified_update_probe";
            {
                boost::nowide::ofstream out(probe.string());
                writable = bool(out);
            }
            fs::remove(probe);
        } catch (const std::exception&) {}

        auto quote = [](const std::wstring& s) { return L"\"" + s + L"\""; };
        const std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + quote(script.wstring()) +
                                  L" -WaitPid " + std::to_wstring(GetCurrentProcessId()) + L" -Zip " + quote(zip.wstring()) +
                                  L" -Dest " + quote(dest.wstring()) + L" -Exe " + quote(exe.wstring()) + L" -Restart " +
                                  (restart ? L"1" : L"0");

        SHELLEXECUTEINFOW info{};
        info.cbSize       = sizeof(info);
        info.fMask        = SEE_MASK_NOASYNC;
        info.lpVerb       = writable ? L"open" : L"runas";
        info.lpFile       = L"powershell.exe";
        info.lpParameters = args.c_str();
        info.nShow        = SW_HIDE;
        if (!ShellExecuteExW(&info))
            BOOST_LOG_TRIVIAL(error) << "Updater: could not start the install script, error " << GetLastError();
        else
            BOOST_LOG_TRIVIAL(info) << "Updater: installing " << zip.string() << " into " << dest.string();
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(error) << "Updater: " << e.what();
    }
#endif
}

}} // namespace Slic3r::GUI
