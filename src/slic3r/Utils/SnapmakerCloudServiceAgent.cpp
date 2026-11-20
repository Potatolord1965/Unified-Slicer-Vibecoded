#include "SnapmakerCloudServiceAgent.hpp"

#include "SnapmakerCloud.hpp"
#include "slic3r/GUI/GUI.hpp"
#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/MsgDialog.hpp"

#include <string>
#include <utility>
#include <vector>

#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>
#include <wx/string.h>

namespace Slic3r {

using nlohmann::json;
namespace SC = SnapmakerCloud;

namespace {
constexpr const char* AGENT_VERSION = "1.0.0";
}

SnapmakerCloudServiceAgent::SnapmakerCloudServiceAgent(std::string log_dir) : m_log_dir(std::move(log_dir)) {}

int SnapmakerCloudServiceAgent::set_config_dir(std::string /*config_dir*/)
{
    // The session file lives in the data directory, next to the other accounts' files.
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudServiceAgent::change_user(std::string user_info)
{
    const json j    = json::parse(user_info, nullptr, false);
    const json data = j.is_object() && j.contains("data") && j["data"].is_object() ? j["data"] : j;
    auto       text = [&data](const char* key) {
        auto it = data.is_object() ? data.find(key) : data.end();
        return data.is_object() && it != data.end() && it->is_string() ? it->get<std::string>() : std::string();
    };

    SC::Session session;
    std::string error;
    const int   code = SC::Client::sign_in_with_token(SC::region_from_string(text("region")), text("token"), session, error);
    if (code != SC::CODE_OK || !session.valid()) {
        BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: sign-in failed (" << code << "): " << error;
        report_login_failure(error.empty() ? _u8L("Sign-in to Snapmaker failed. Try again.") : error);
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }

    SC::SessionStore::set(session);
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_last_error.clear();
    }
    BOOST_LOG_TRIVIAL(info) << "SnapmakerCloud: signed in as user " << session.user_id;
    return BAMBU_NETWORK_SUCCESS;
}

void SnapmakerCloudServiceAgent::report_login_failure(const std::string& error)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_last_error = error;
    }
    // change_user runs on the UI thread once the login dialog has closed, so this is the only place the user sees why.
    GUI::MessageDialog dlg(nullptr, GUI::from_u8(error), _L("Snapmaker"), wxOK | wxICON_WARNING);
    dlg.ShowModal();
}

std::string SnapmakerCloudServiceAgent::last_error() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_last_error;
}

bool SnapmakerCloudServiceAgent::is_user_login() { return SC::SessionStore::get().valid(); }

int SnapmakerCloudServiceAgent::user_logout(bool /*request*/)
{
    SC::SessionStore::clear();
    return BAMBU_NETWORK_SUCCESS;
}

std::string SnapmakerCloudServiceAgent::get_user_id() { return SC::SessionStore::get().user_id; }

std::string SnapmakerCloudServiceAgent::get_user_name()
{
    const SC::Session s = SC::SessionStore::get();
    return !s.nickname.empty() ? s.nickname : !s.account.empty() ? s.account : s.user_id;
}

std::string SnapmakerCloudServiceAgent::get_user_avatar() { return SC::SessionStore::get().avatar; }

std::string SnapmakerCloudServiceAgent::get_user_nickname() { return SC::SessionStore::get().nickname; }

std::string SnapmakerCloudServiceAgent::build_login_cmd()
{
    return json{{"command", "snapmaker_userlogin"}, {"data", json::parse(build_login_info())}}.dump();
}

std::string SnapmakerCloudServiceAgent::build_logout_cmd() { return json{{"command", "snapmaker_useroffline"}}.dump(); }

std::string SnapmakerCloudServiceAgent::build_login_info()
{
    const SC::Session s = SC::SessionStore::get();
    // The token stays out of anything handed to a web page.
    return json{{"user_id", s.user_id},
                {"nickname", s.nickname},
                {"avatar", s.avatar},
                {"logged_in", s.valid()},
                {"region", SC::region_to_string(s.region)}}
        .dump();
}

std::string SnapmakerCloudServiceAgent::get_access_token() const { return SC::SessionStore::get().token; }

bool SnapmakerCloudServiceAgent::ensure_token_fresh(const std::string& /*reason*/)
{
    // No refresh flow: an expired token surfaces as 401 and needs a new sign-in.
    return SC::SessionStore::get().valid();
}

std::string SnapmakerCloudServiceAgent::get_cloud_service_host()
{
    return SC::SessionStore::get().region == SC::Region::China ? "id.snapmaker.cn" : "id.snapmaker.com";
}

std::string SnapmakerCloudServiceAgent::get_cloud_login_url(const std::string& /*language*/)
{
    return SC::login_url(SC::SessionStore::get().region);
}

int SnapmakerCloudServiceAgent::get_user_print_info(unsigned int* http_code, std::string* http_body)
{
    const SC::Session s = SC::SessionStore::get();
    if (!s.valid())
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    std::vector<SC::Device> devices;
    std::string             error;
    const int               code = SC::Client(s).list_devices(devices, error);
    if (http_code)
        *http_code = code == SC::CODE_OK ? 200 : (code == SC::CODE_UNAUTHORIZED ? 401 : 500);
    if (code != SC::CODE_OK) {
        if (http_body)
            *http_body = json{{"error", error}, {"code", code}}.dump();
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }
    json list = json::array();
    for (const SC::Device& d : devices)
        list.push_back({{"dev_id", d.sn}, {"dev_name", d.name}, {"dev_type", d.model}, {"online", d.online}, {"status", d.online ? "Online" : "Offline"}});
    if (http_body)
        *http_body = json{{"devices", list}}.dump();
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudServiceAgent::get_user_info(int* identifier)
{
    if (identifier) {
        try {
            *identifier = std::stoi(SC::SessionStore::get().user_id);
        } catch (...) {
            *identifier = 0;
        }
    }
    return is_user_login() ? BAMBU_NETWORK_SUCCESS : BAMBU_NETWORK_ERR_INVALID_HANDLE;
}

std::string SnapmakerCloudServiceAgent::get_version() { return AGENT_VERSION; }

int SnapmakerCloudServiceAgent::set_on_server_connected_fn(AppOnServerConnectedFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_on_server_connected = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudServiceAgent::set_on_http_error_fn(AppOnHttpErrorFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_on_http_error = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudServiceAgent::set_queue_on_main_fn(QueueOnMainFn fn)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue_on_main = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

} // namespace Slic3r
