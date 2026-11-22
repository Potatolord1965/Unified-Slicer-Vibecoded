#include "CrealityCloudServiceAgent.hpp"

#include "CrealityCloud.hpp"
#include "libslic3r/Utils.hpp"
#include "slic3r/GUI/GUI.hpp"
#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/MsgDialog.hpp"
#include "slic3r/GUI/Widgets/ProgressDialog.hpp"

#include <chrono>
#include <future>
#include <utility>
#include <vector>

#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>
#include <wx/progdlg.h>
#include <wx/string.h>

namespace Slic3r {

using nlohmann::json;
namespace CC = CrealityCloud;

namespace {
constexpr const char* AGENT_VERSION = "1.0.0";
}

CrealityCloudServiceAgent::CrealityCloudServiceAgent(std::string log_dir) : m_log_dir(std::move(log_dir)) {}

int CrealityCloudServiceAgent::set_config_dir(std::string /*config_dir*/)
{
    // The session file lives in the data directory, next to the Orca account's files.
    return BAMBU_NETWORK_SUCCESS;
}

int CrealityCloudServiceAgent::change_user(std::string user_info)
{
    const json j    = json::parse(user_info, nullptr, false);
    const json data = j.is_object() && j.contains("data") && j["data"].is_object() ? j["data"] : j;
    if (!data.is_object()) {
        report_login_failure(_u8L("Unexpected reply from the sign-in page."));
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }
    auto text = [&data](const char* key) {
        auto it = data.find(key);
        return it != data.end() && it->is_string() ? it->get<std::string>() : std::string();
    };

    const CC::Region  region       = CC::region_from_string(text("region"));
    const auto        type_it      = data.find("account_type");
    const int         account_type = type_it != data.end() && type_it->is_number_integer() ? type_it->get<int>() : 2;
    const std::string account = text("account"), password = text("password"), token = text("token"), user_id = text("userId");
    CC::Session       session;
    std::string       error;

    // change_user runs on the GUI thread and the request can take half a minute, so it runs on a
    // worker while an app-modal progress window keeps the app drawing.
    std::future<int> request = std::async(std::launch::async, [&]() {
        if (!password.empty())
            return CC::Client::login(region, account_type, account, password, session, error);
        if (!token.empty() && !user_id.empty()) {
            // A session handed over directly, e.g. by a future OAuth page.
            session.region  = region;
            session.token   = token;
            session.user_id = user_id;
            CC::Client(session).fetch_user_info(session);
            return int(CC::CODE_OK);
        }
        return int(CC::CODE_PARSE);
    });
    {
        GUI::ProgressDialog progress(_L("Creality Cloud"), _L("Signing in…"), 100, nullptr, wxPD_APP_MODAL | wxPD_AUTO_HIDE);
        while (request.wait_for(std::chrono::milliseconds(100)) != std::future_status::ready)
            progress.Pulse();
    }
    const int code = request.get();

    if (code != CC::CODE_OK || !session.valid()) {
        BOOST_LOG_TRIVIAL(warning) << "CrealityCloud: sign-in failed (" << code << "): " << error;
        report_login_failure(error.empty() ? _u8L("Sign-in failed. Check the account and password.") : error);
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }

    CC::SessionStore::set(session);
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_last_error.clear();
    }
    BOOST_LOG_TRIVIAL(info) << "CrealityCloud: signed in as user " << session.user_id;
    return BAMBU_NETWORK_SUCCESS;
}

void CrealityCloudServiceAgent::report_login_failure(const std::string& error)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_last_error = error;
    }
    // change_user runs on the UI thread once the login dialog has closed, so this is the only place the user sees why.
    GUI::MessageDialog dlg(nullptr, GUI::from_u8(error), _L("Creality Cloud"), wxOK | wxICON_WARNING);
    dlg.ShowModal();
}

std::string CrealityCloudServiceAgent::last_error() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_last_error;
}

bool CrealityCloudServiceAgent::is_user_login() { return CC::SessionStore::get().valid(); }

int CrealityCloudServiceAgent::user_logout(bool /*request*/)
{
    CC::SessionStore::clear();
    return BAMBU_NETWORK_SUCCESS;
}

std::string CrealityCloudServiceAgent::get_user_id() { return CC::SessionStore::get().user_id; }

std::string CrealityCloudServiceAgent::get_user_name()
{
    const CC::Session s = CC::SessionStore::get();
    return s.nickname.empty() ? s.user_id : s.nickname;
}

std::string CrealityCloudServiceAgent::get_user_avatar() { return CC::SessionStore::get().avatar; }

std::string CrealityCloudServiceAgent::get_user_nickname() { return CC::SessionStore::get().nickname; }

std::string CrealityCloudServiceAgent::build_login_cmd()
{
    return json{{"command", "creality_userlogin"}, {"data", json::parse(build_login_info())}}.dump();
}

std::string CrealityCloudServiceAgent::build_logout_cmd() { return json{{"command", "creality_useroffline"}}.dump(); }

std::string CrealityCloudServiceAgent::build_login_info()
{
    const CC::Session s = CC::SessionStore::get();
    // The token stays out of anything handed to a web page.
    return json{{"user_id", s.user_id},
                {"nickname", s.nickname},
                {"avatar", s.avatar},
                {"logged_in", s.valid()},
                {"region", CC::region_to_string(s.region)}}
        .dump();
}

std::string CrealityCloudServiceAgent::get_access_token() const { return CC::SessionStore::get().token; }

bool CrealityCloudServiceAgent::ensure_token_fresh(const std::string& /*reason*/)
{
    // Creality tokens are long-lived and have no refresh flow; an expired one surfaces as code 4 and needs a new sign-in.
    return CC::SessionStore::get().valid();
}

std::string CrealityCloudServiceAgent::get_cloud_service_host() { return CC::api_base_url(CC::SessionStore::get().region); }

std::string CrealityCloudServiceAgent::get_cloud_login_url(const std::string& /*language*/)
{
    return GUI::into_u8(GUI::file_url_from_path(boost::filesystem::path(resources_dir()) / "web/creality/login.html"));
}

int CrealityCloudServiceAgent::get_user_print_info(unsigned int* http_code, std::string* http_body)
{
    const CC::Session s = CC::SessionStore::get();
    if (!s.valid())
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    std::vector<CC::Device> devices;
    std::string             error;
    const int               code = CC::Client(s).list_devices(devices, error);
    if (http_code)
        *http_code = code == CC::CODE_OK ? 200 : (code == CC::CODE_TOKEN_INVALID ? 401 : 500);
    if (code != CC::CODE_OK) {
        if (http_body)
            *http_body = json{{"error", error}, {"code", code}}.dump();
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }
    json list = json::array();
    for (const CC::Device& d : devices)
        list.push_back({{"dev_id", d.dn},
                        {"dev_name", d.name},
                        {"dev_type", d.model},
                        {"online", d.online},
                        {"status", CC::print_state_text(d.state)},
                        {"progress", d.progress}});
    if (http_body)
        *http_body = json{{"devices", list}}.dump();
    return BAMBU_NETWORK_SUCCESS;
}

int CrealityCloudServiceAgent::get_user_info(int* identifier)
{
    if (identifier) {
        try {
            *identifier = std::stoi(CC::SessionStore::get().user_id);
        } catch (...) {
            *identifier = 0;
        }
    }
    return is_user_login() ? BAMBU_NETWORK_SUCCESS : BAMBU_NETWORK_ERR_INVALID_HANDLE;
}

std::string CrealityCloudServiceAgent::get_version() { return AGENT_VERSION; }

int CrealityCloudServiceAgent::set_on_server_connected_fn(AppOnServerConnectedFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_on_server_connected = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

int CrealityCloudServiceAgent::set_on_http_error_fn(AppOnHttpErrorFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_on_http_error = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

int CrealityCloudServiceAgent::set_queue_on_main_fn(QueueOnMainFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue_on_main = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

} // namespace Slic3r
