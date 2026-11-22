#include "UnifiedUpdater.hpp"

#include <algorithm>
#include <cstddef>
#include <exception>
#include <functional>
#include <ios>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/fstream.hpp>
#include <boost/optional/optional.hpp>
#include <boost/system/error_code.hpp>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <openssl/ossl_typ.h> // IWYU pragma: keep
#include <wx/app.h>

#include "libslic3r/AppConfig.hpp"
#include "libslic3r/Semver.hpp"
#include "libslic3r/Utils.hpp"
#include "libslic3r/format.hpp"
#include "libslic3r_version.h"
#include "slic3r/Utils/Http.hpp"
#include "slic3r/Utils/UpdateSignature.hpp"
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
constexpr const char* UNIFIED_UPDATE_REPO = "Potatolord1965/Unified-Slicer-Vibecoded";
constexpr const char* AUTO_INSTALL_KEY    = "auto_install_updates";
constexpr const char* INSTALL_LOG_NAME    = "apply_update.log";
constexpr size_t      MAX_PACKAGE_SIZE    = size_t(2) * 1024 * 1024 * 1024 - 1;
constexpr size_t      MAX_SMALL_ASSET     = 64 * 1024;

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

boost::optional<Semver> parse_tag(std::string tag)
{
    if (!tag.empty() && (tag.front() == 'v' || tag.front() == 'V'))
        tag.erase(0, 1);
    return Semver::parse(tag);
}

std::string network_error(const std::string& error, unsigned status) { return error.empty() ? "HTTP " + std::to_string(status) : error; }

#ifdef _WIN32
// A PowerShell single-quoted string literal. PowerShell also treats the typographic single quotes
// as quotes, so they are doubled too.
std::wstring ps_literal(const std::wstring& s)
{
    std::wstring out = L"'";
    for (wchar_t c : s) {
        if (c == L'\'' || c == 0x2018 || c == 0x2019 || c == 0x201A || c == 0x201B)
            out += c;
        out += c;
    }
    return out + L"'";
}

// powershell.exe -EncodedCommand takes base64 of the script in UTF-16LE.
std::wstring encode_command(const std::wstring& script)
{
    std::string bytes;
    bytes.reserve(script.size() * 2);
    for (wchar_t c : script) {
        bytes.push_back(char(c & 0xff));
        bytes.push_back(char((c >> 8) & 0xff));
    }
    std::string b64(4 * ((bytes.size() + 2) / 3) + 1, '\0');
    const int   len = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(&b64[0]), reinterpret_cast<const unsigned char*>(bytes.data()),
                                      int(bytes.size()));
    b64.resize(size_t(std::max(len, 0)));
    return std::wstring(b64.begin(), b64.end());
}

// The install helper. It runs without administrator rights, so the app it restarts doesn't get them
// either, and it is passed on the command line, so there is no script file to swap. It waits for the
// app to exit, runs apply_update.ps1 from the install folder (through UAC when `elevate`), records the
// outcome in the user's update log, deletes the installed package and restarts the app when asked.
std::wstring install_helper(DWORD pid, const fs::path& script, const fs::path& zip, const std::string& digest, const fs::path& dest,
                            const fs::path& exe, const fs::path& log, const std::string& zip_name, bool elevate, bool restart)
{
    std::wstring dest_arg = dest.wstring();
    // A quoted argument may not end in a backslash ("C:\" would escape its closing quote).
    if (!dest_arg.empty() && dest_arg.back() == L'\\')
        dest_arg += L'.';
    // Paths on Windows can't contain double quotes, so quoting each one is enough.
    const std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script.wstring() + L"\" -Zip \"" + zip.wstring() +
                              L"\" -Hash " + std::wstring(digest.begin(), digest.end()) + L" -Dest \"" + dest_arg + L"\" -Exe \"" +
                              exe.filename().wstring() + L"\"";
    const std::wstring flag_elevate = elevate ? L"$true" : L"$false";
    const std::wstring flag_restart = restart ? L"$true" : L"$false";
    std::wstring s;
    s += L"$ErrorActionPreference = 'Stop'\n";
    s += L"$log = " + ps_literal(log.wstring()) + L"\n";
    s += L"function Log($m) { Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + ' ' + $m) }\n";
    s += L"try { Wait-Process -Id " + std::to_wstring(pid) + L" -Timeout 120 -ErrorAction SilentlyContinue } catch {}\n";
    s += L"$argList = " + ps_literal(args) + L"\n";
    s += L"$inner = " + ps_literal((dest / INSTALL_LOG_NAME).wstring()) + L"\n";
    s += L"try {\n";
    s += L"    if (" + flag_elevate + L") { $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -Wait -PassThru }\n";
    s += L"    else { $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -Wait -PassThru }\n";
    s += L"    if ($p.ExitCode -eq 0) {\n";
    s += L"        Log 'installed'\n";
    s += L"        Remove-Item -LiteralPath " + ps_literal(zip.wstring()) + L" -Force -ErrorAction SilentlyContinue\n";
    s += L"    } else {\n";
    s += L"        $detail = 'exit code ' + $p.ExitCode\n";
    s += L"        if (Test-Path -LiteralPath $inner) {\n";
    s += L"            $line = [string](Get-Content -LiteralPath $inner -Tail 1)\n";
    s += L"            $i = $line.IndexOf(' failed: ')\n";
    s += L"            if ($i -ge 0) { $detail = $line.Substring($i + 9) }\n";
    s += L"        }\n";
    s += L"        Log ('failed: ' + $detail)\n";
    s += L"    }\n";
    s += L"} catch {\n";
    // Start-Process only throws for the elevated run when UAC was declined.
    s += L"    if (" + flag_elevate + L") { Log " + ps_literal(L"declined " + fs::path(zip_name).wstring()) + L" } else { Log ('failed: ' + $_) }\n";
    s += L"}\n";
    s += L"if (" + flag_restart + L") { Start-Process -FilePath " + ps_literal(exe.wstring()) + L" }\n";
    return s;
}
#endif

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

// The install helper appends "installed", "failed: <reason>" or "declined <package>".
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
        const size_t failed   = last.find(" failed: ");
        const size_t declined = last.find(" declined ");
        if (failed != std::string::npos)
            m_last_install_error = last.substr(failed + 9);
        else if (declined != std::string::npos)
            m_declined_package = last.substr(declined + 10);
    } catch (const std::exception&) {}
}

UnifiedUpdater::State UnifiedUpdater::state() const { std::lock_guard<std::mutex> lock(m_mutex); return m_state; }
UnifiedUpdater::Release UnifiedUpdater::release() const { std::lock_guard<std::mutex> lock(m_mutex); return m_release; }
std::string UnifiedUpdater::error() const { std::lock_guard<std::mutex> lock(m_mutex); return m_error; }
double UnifiedUpdater::progress() const { std::lock_guard<std::mutex> lock(m_mutex); return m_progress; }

std::string UnifiedUpdater::last_install_error() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_declined_package.empty() && m_declined_package == m_release.zip_name)
        return _u8L("Windows did not get administrator rights to install it. Use \"Restart and update\" to try again.");
    return m_last_install_error;
}

bool UnifiedUpdater::install_declined() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return !m_declined_package.empty() && m_declined_package == m_release.zip_name;
}

bool UnifiedUpdater::can_install() const
{
#ifdef _WIN32
    std::lock_guard<std::mutex> lock(m_mutex);
    return !m_release.zip_url.empty() && !m_release.sha256_url.empty() && !m_release.sig_url.empty();
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
        .tls_verify(true)
        .timeout_connect(10)
        .timeout_max(30)
        .on_error([this](std::string, std::string error, unsigned status) {
            // 404: the repository has no published release yet.
            if (status == 404)
                set_state(State::UpToDate);
            else
                set_state(State::Failed, format(_u8L("Could not reach GitHub: %1%"), network_error(error, status)));
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
                // Only the package named after the release's own version: its name is in the signed
                // checksum file, so an older signed package can't be passed off as this release.
                const std::string zip_name = "UnifiedSlicer-" + rel.version + "-win64.zip";
                const auto        assets   = json.value("assets", nlohmann::json::array());
                auto              find     = [&assets](const std::string& name, size_t* size = nullptr) {
                    for (const auto& asset : assets)
                        if (asset.is_object() && boost::iequals(asset.value("name", ""), name)) {
                            if (size != nullptr)
                                *size = asset.value("size", size_t(0));
                            return asset.value("browser_download_url", "");
                        }
                    return std::string();
                };
                rel.zip_url = find(zip_name, &rel.zip_size);
                if (!rel.zip_url.empty()) {
                    rel.zip_name   = zip_name;
                    rel.sha256_url = find(zip_name + ".sha256");
                    rel.sig_url    = find(zip_name + ".sha256.sig");
                }
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    m_release  = rel;
                    m_progress = 0.;
                }
                set_state(State::Available);
                // The settings are read on the GUI thread only.
                if (wxTheApp != nullptr)
                    wxTheApp->CallAfter([this]() {
                        if (state() == State::Available && auto_install_enabled() && can_install())
                            download();
                    });
            } catch (const std::exception& e) {
                set_state(State::Failed, format(_u8L("Unexpected answer from GitHub: %1%"), e.what()));
            }
        })
        .perform();
}

void UnifiedUpdater::fetch_asset(const std::string& url, std::function<void(std::string)> then)
{
    Http::get(url)
        .tls_verify(true)
        .size_limit(MAX_SMALL_ASSET)
        .timeout_connect(10)
        .timeout_max(60)
        .on_error([this](std::string, std::string error, unsigned status) {
            set_state(State::Failed, format(_u8L("Could not download the update checksum: %1%"), network_error(error, status)));
        })
        .on_complete([then](std::string body, unsigned) { then(std::move(body)); })
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

    // The signed checksum first: it decides which package is trusted, and whether one left over from
    // an earlier session can be used.
    fetch_asset(rel.sha256_url, [this, rel](std::string checksum) {
        fetch_asset(rel.sig_url, [this, rel, checksum](std::string signature) { download_verified(rel, checksum, signature); });
    });
}

void UnifiedUpdater::download_verified(const Release& rel, const std::string& checksum, const std::string& signature)
{
    if (!UpdateSignature::verify(checksum, signature)) {
        set_state(State::Failed, _u8L("The update is not signed with the Unified Slicer release key, so it was not downloaded."));
        return;
    }
    std::string digest, file_name;
    if (!UpdateSignature::parse_checksum(checksum, digest, file_name) || !boost::iequals(file_name, rel.zip_name)) {
        set_state(State::Failed, _u8L("The update checksum file is not valid."));
        return;
    }
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_sha256 = digest;
    }
    const fs::path target  = fs::path(updates_dir()) / rel.zip_name;
    const fs::path partial = target.string() + ".part";
    try {
        fs::create_directories(target.parent_path());
        if (fs::exists(target) && sha256_of_file(target) == digest) {
            set_state(State::Ready);
            return;
        }
    } catch (const std::exception& e) {
        set_state(State::Failed, format(_u8L("Could not prepare the update folder: %1%"), e.what()));
        return;
    }

    Http::get(rel.zip_url)
        .tls_verify(true)
        .size_limit(MAX_PACKAGE_SIZE)
        .timeout_connect(15)
        .body_to_file(partial)
        .on_progress([this](Http::Progress p, bool&) {
            if (p.dltotal == 0)
                return;
            const double now = double(p.dlnow) / double(p.dltotal);
            bool         changed;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                changed = now - m_progress >= 0.01 || now >= 1.;
                if (changed)
                    m_progress = now;
            }
            if (changed)
                notify();
        })
        .on_error([this, partial](std::string, std::string error, unsigned status) {
            boost::system::error_code ec;
            fs::remove(partial, ec);
            set_state(State::Failed, format(_u8L("Could not download the update: %1%"), network_error(error, status)));
        })
        .on_complete([this, target, partial, digest](std::string, unsigned) {
            try {
                if (sha256_of_file(partial) != digest) {
                    fs::remove(partial);
                    set_state(State::Failed, _u8L("The downloaded update does not match its signed checksum."));
                    return;
                }
                fs::rename(partial, target);
                set_state(State::Ready);
            } catch (const std::exception& e) {
                set_state(State::Failed, format(_u8L("Could not save the update: %1%"), e.what()));
            }
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
    // is still installed when the app is closed later, only without the restart. Deferred so that a
    // modal dialog that asked for this has finished closing first.
    wxGetApp().CallAfter([]() {
        if (MainFrame* frame = wxGetApp().mainframe)
            frame->Close();
    });
}

void UnifiedUpdater::install_pending()
{
#ifdef _WIN32
    bool        restart;
    std::string digest, zip_name;
    bool        declined;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state != State::Ready)
            return;
        restart  = m_restart_after_install;
        digest   = m_sha256;
        zip_name = m_release.zip_name;
        declined = !m_declined_package.empty() && m_declined_package == zip_name;
    }
    // Refused administrator rights once: only "Restart and update" asks again, not every exit.
    if (!restart && (!auto_install_enabled() || declined))
        return;
    try {
        const fs::path zip = package_path();
        // Checked again: the file sat in the user's data folder since it was downloaded.
        // apply_update.ps1 checks its own copy once more before installing it.
        if (zip.empty() || digest.empty() || sha256_of_file(zip) != digest) {
            BOOST_LOG_TRIVIAL(error) << "Updater: package missing or changed, not installing";
            return;
        }
        const fs::path script = fs::path(resources_dir()) / "updater" / "apply_update.ps1";
        if (!fs::exists(script)) {
            BOOST_LOG_TRIVIAL(error) << "Updater: " << script.string() << " is missing, not installing";
            return;
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

        const std::wstring helper = install_helper(GetCurrentProcessId(), script, zip, digest, dest, exe,
                                                   fs::path(updates_dir()) / INSTALL_LOG_NAME, zip_name, !writable, restart);
        const std::wstring args   = L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " + encode_command(helper);

        SHELLEXECUTEINFOW info{};
        info.cbSize       = sizeof(info);
        info.fMask        = SEE_MASK_NOASYNC;
        info.lpVerb       = L"open";
        info.lpFile       = L"powershell.exe";
        info.lpParameters = args.c_str();
        info.nShow        = SW_HIDE;
        if (!ShellExecuteExW(&info))
            BOOST_LOG_TRIVIAL(error) << "Updater: could not start the install helper, error " << GetLastError();
        else
            BOOST_LOG_TRIVIAL(info) << "Updater: installing " << zip.string() << " into " << dest.string();
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(error) << "Updater: " << e.what();
    }
#endif
}

}} // namespace Slic3r::GUI
