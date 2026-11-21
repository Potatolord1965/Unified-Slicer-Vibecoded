#include "BuiltinCloudProviders.hpp"
#include "CloudAccounts.hpp"
#include "DeviceHubPanel.hpp"
#include "slic3r/GUI/BusyWork.hpp"

#include <functional>
#include <utility>

#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>
#include <wx/app.h>
#include <wx/dialog.h>
#include <wx/sizer.h>
#include <wx/stattext.h>
#include <wx/textctrl.h>

#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/Time.hpp"
#include "libslic3r/Utils.hpp"
#include "slic3r/GUI/DeviceCore/DevManager.h"
#include "slic3r/GUI/DeviceCore/DevConfigUtil.h"
#include <set>
#include "slic3r/GUI/DeviceManager.hpp"
#include "slic3r/GUI/GUI.hpp"
#include "slic3r/GUI/GUI_App.hpp"
#include "slic3r/GUI/I18N.hpp"
#include "slic3r/GUI/format.hpp"
#include "slic3r/GUI/MainFrame.hpp"
#include "slic3r/GUI/MsgDialog.hpp"
#include "slic3r/Utils/CloudProvider.hpp"
#include "slic3r/Utils/CrealityCloud.hpp"
#include "slic3r/Utils/ElegooCloud.hpp"
#include "slic3r/Utils/Http.hpp"
#include "slic3r/Utils/MarkforgedEiger.hpp"
#include "slic3r/Utils/PhoneSignIn.hpp"
#include "slic3r/GUI/ElegooLoginDialog.hpp"
#include "slic3r/GUI/ElegooCloudMonitor.hpp"
#include <wx/utils.h>
#include <atomic>
#include <mutex>
#include <thread>
#include "slic3r/Utils/ICloudServiceAgent.hpp"
#include "slic3r/Utils/IPrinterAgent.hpp"
#include "slic3r/Utils/NetworkAgent.hpp"
#include "slic3r/Utils/NetworkAgentFactory.hpp"

namespace Slic3r { namespace GUI {

namespace {

// The printer agent a printer preset uses, with the vendor default filled in.
std::string effective_agent_id(const DynamicPrintConfig& printer_config)
{
    const auto* opt = printer_config.option<ConfigOptionString>("printer_agent");
    return wxGetApp().resolve_printer_agent_id(opt != nullptr ? opt->value : std::string());
}

wxString print_status_text(const std::string& status)
{
    if (status == "RUNNING" || status == "PREPARE" || status == "SLICING")
        return _L("Printing");
    if (status == "PAUSE")
        return _L("Paused");
    if (status == "FINISH")
        return _L("Finished");
    if (status == "FAILED")
        return _L("Failed");
    return _L("Idle");
}

} // namespace

// ---------------------------------------------------------------------------------------------
// BambuCloudProvider
// ---------------------------------------------------------------------------------------------

std::string BambuCloudProvider::id() const { return BBL_CLOUD_PROVIDER; }

wxString BambuCloudProvider::display_name() const { return "Bambu Lab"; }

bool BambuCloudProvider::is_available() const
{
    NetworkAgent* agent = wxGetApp().getAgent();
    return agent != nullptr && agent->get_cloud_agent(BBL_CLOUD_PROVIDER) != nullptr;
}

wxString BambuCloudProvider::unavailable_reason() const
{
    return _L("Bambu Lab printers need the Bambu network plug-in. It is downloaded from Bambu Lab when you install it.");
}

void BambuCloudProvider::install_or_enable(wxWindow* /*parent*/) { wxGetApp().ShowDownNetPluginDlg(); }

bool BambuCloudProvider::is_logged_in() const { return wxGetApp().is_user_login(BBL_CLOUD_PROVIDER); }

wxString BambuCloudProvider::account_name() const
{
    NetworkAgent* agent = wxGetApp().getAgent();
    if (agent == nullptr)
        return {};
    std::shared_ptr<ICloudServiceAgent> cloud = agent->get_cloud_agent(BBL_CLOUD_PROVIDER);
    if (!cloud || !cloud->is_user_login())
        return {};
    std::string name = cloud->get_user_nickname();
    if (name.empty())
        name = cloud->get_user_name();
    return from_u8(name);
}

void BambuCloudProvider::login(wxWindow* /*parent*/)
{
    wxGetApp().request_login(true, BBL_CLOUD_PROVIDER);
    CloudPrinterProviders::notify_changed(id());
}

void BambuCloudProvider::logout()
{
    wxGetApp().request_user_logout(BBL_CLOUD_PROVIDER, true);
    CloudPrinterProviders::notify_changed(id());
}

namespace {

// The Bambu account's printers as the cloud last listed them. The DeviceManager keeps a machine
// list only for the live printer agent's account, so with another brand's preset selected it has
// no Bambu printers at all; the hub asks the account itself.
struct BambuCloudPrinter
{
    std::string name;
    std::string model;
    std::string model_id; // dev_model_name, e.g. "C11"
    bool        online{false};
    std::string task_status;
};
std::mutex                               s_bambu_mutex;
std::map<std::string, BambuCloudPrinter> s_bambu_cloud;
std::atomic<long long>                   s_bambu_last_fetch{0};
std::atomic<bool>                        s_bambu_fetching{false};

void parse_bambu_cloud_list(const std::string& body)
{
    std::map<std::string, BambuCloudPrinter> list;
    const nlohmann::json j = nlohmann::json::parse(body);
    if (!j.contains("devices") || !j["devices"].is_array())
        return; // no list in the answer: keep the last one
    for (const nlohmann::json& d : j["devices"]) {
        const std::string dev_id = d.contains("dev_id") && d["dev_id"].is_string() ? d["dev_id"].get<std::string>() : std::string();
        if (dev_id.empty())
            continue;
        BambuCloudPrinter p;
        p.name = d.contains("dev_name") && d["dev_name"].is_string() ? d["dev_name"].get<std::string>() : dev_id;
        const std::string model = d.contains("dev_model_name") && d["dev_model_name"].is_string() ? d["dev_model_name"].get<std::string>() : std::string();
        p.model_id = model;
        if (!model.empty())
            p.model = DevPrinterConfigUtil::get_printer_display_name(model);
        if (p.model.empty() && d.contains("dev_product_name") && d["dev_product_name"].is_string())
            p.model = d["dev_product_name"].get<std::string>();
        if (p.model.empty())
            p.model = model;
        p.online      = d.contains("dev_online") && d["dev_online"].is_boolean() && d["dev_online"].get<bool>();
        p.task_status = d.contains("task_status") && d["task_status"].is_string() ? d["task_status"].get<std::string>() : std::string();
        list.emplace(dev_id, std::move(p));
    }
    std::lock_guard<std::mutex> lock(s_bambu_mutex);
    s_bambu_cloud = std::move(list);
}

void reset_bambu_cloud_list()
{
    std::lock_guard<std::mutex> lock(s_bambu_mutex);
    s_bambu_cloud.clear();
    s_bambu_last_fetch = 0;
}

std::string bambu_api_base(const nlohmann::json& data)
{
    return data.value("region", std::string()) == "CN" ? "https://api.bambulab.cn" : "https://api.bambulab.com";
}

// One HTTP call to Bambu's cloud API with the account's own token; the status and body come back.
unsigned bambu_api(Http http, std::string& body)
{
    unsigned status = 0;
    http.header("Accept", "application/json").tls_verify(true).timeout_connect(10).timeout_max(30)
        .on_complete([&](std::string b, unsigned s) { body = std::move(b); status = s; })
        .on_error([&](std::string b, std::string, unsigned s) { body = std::move(b); status = s; })
        .perform_sync();
    return status;
}

// The printers of a saved Bambu account that is not the plug-in's: the same list Bambu Handy
// shows, with the account's token. A rejected token is renewed once with the refresh token, and
// the saved sign-in (including the message that signs the plug-in in to it) takes the new one.
std::vector<CloudPrinter> fetch_bambu_account(nlohmann::json& data)
{
    const std::string base = bambu_api_base(data);
    auto list = [&](std::string& body) {
        Http http = Http::get(base + "/v1/iot-service/api/user/bind");
        http.header("Authorization", "Bearer " + data.value("access_token", std::string()));
        return bambu_api(std::move(http), body);
    };
    std::string body;
    unsigned    status = list(body);
    if ((status == 401 || status == 403) && !data.value("refresh_token", std::string()).empty()) {
        std::string reply;
        Http        http = Http::post(base + "/v1/user-service/user/refreshtoken");
        http.header("Content-Type", "application/json").set_post_body(nlohmann::json{{"refreshToken", data.value("refresh_token", std::string())}}.dump());
        if (bambu_api(std::move(http), reply) == 200) {
            const nlohmann::json j = nlohmann::json::parse(reply, nullptr, false);
            if (j.is_object() && j.contains("accessToken") && j["accessToken"].is_string()) {
                data["access_token"]  = j["accessToken"];
                data["refresh_token"] = j.value("refreshToken", data.value("refresh_token", std::string()));
                nlohmann::json msg    = nlohmann::json::parse(data.value("login_message", std::string()), nullptr, false);
                if (msg.is_object() && msg.contains("data") && msg["data"].is_object()) {
                    msg["data"]["token"]         = data["access_token"];
                    msg["data"]["refresh_token"] = data["refresh_token"];
                    data["login_message"]        = msg.dump();
                }
                status = list(body);
            }
        }
    }
    if (status == 401 || status == 403)
        throw std::runtime_error(_u8L("Signed out. Sign in to this account again on the Accounts tab."));
    const nlohmann::json j = nlohmann::json::parse(body, nullptr, false);
    if (status != 200 || !j.is_object() || !j.contains("devices") || !j["devices"].is_array())
        throw std::runtime_error(_u8L("Could not reach the Bambu Lab cloud."));

    std::vector<CloudPrinter> out;
    for (const nlohmann::json& d : j["devices"]) {
        auto str = [&d](const char* key) { return d.contains(key) && d[key].is_string() ? d[key].get<std::string>() : std::string(); };
        CloudPrinter p;
        p.id = str("dev_id");
        if (p.id.empty())
            continue;
        p.name                 = from_u8(str("name").empty() ? p.id : str("name"));
        const std::string code = str("dev_model_name");
        std::string       model = code.empty() ? std::string() : DevPrinterConfigUtil::get_printer_display_name(code);
        if (model.empty())
            model = str("dev_product_name");
        p.model  = from_u8(model.empty() ? code : model);
        p.image  = code.empty() ? std::string() : "printer_preview_" + code;
        p.online = d.contains("online") && d["online"].is_boolean() && d["online"].get<bool>();
        const std::string status_code = str("print_status");
        p.status = !p.online ? _L("Offline") : status_code.empty() ? _L("Online") : print_status_text(status_code);
        out.push_back(std::move(p));
    }
    return out;
}

} // namespace

BambuCloudProvider::BambuCloudProvider()
{
    m_others = std::make_shared<OtherAccountPrinters>(BBL_CLOUD_PROVIDER, fetch_bambu_account);
    auto cloud = [] {
        NetworkAgent* agent = wxGetApp().getAgent();
        return agent != nullptr ? agent->get_cloud_agent(BBL_CLOUD_PROVIDER) : nullptr;
    };
    CloudAccountSet::Hooks hooks;
    hooks.active_key = [cloud] {
        std::shared_ptr<ICloudServiceAgent> c = cloud();
        return c && c->is_user_login() ? c->get_user_id() : std::string();
    };
    hooks.active_label = [this] { return into_u8(account_name()); };
    // The plug-in keeps its tokens to itself: the sign-in is the "user_login" message its page
    // reported, which PhoneSignIn keeps for the account signed in last.
    hooks.capture = [cloud]() -> nlohmann::json {
        std::shared_ptr<ICloudServiceAgent> c = cloud();
        const PhoneSignIn::BambuSession     s = PhoneSignIn::bambu_session();
        if (!c || s.login_message.empty() || s.user_id != c->get_user_id())
            return nullptr;
        const bool china = wxGetApp().app_config != nullptr && wxGetApp().app_config->get_country_code() == "CN";
        return {{"login_message", s.login_message},
                {"access_token", s.access_token},
                {"refresh_token", s.refresh_token},
                {"region", china ? "CN" : "global"}};
    };
    hooks.apply = [this](const nlohmann::json& data) {
        NetworkAgent* agent = wxGetApp().getAgent();
        const std::string message = data.value("login_message", std::string());
        if (agent == nullptr || message.empty())
            return false;
        // What the sign-in page does when it reports a login (GUI_App::handle_script_message).
        agent->change_user(message, BBL_CLOUD_PROVIDER);
        reset_bambu_cloud_list();
        m_others->invalidate();
        if (!agent->is_user_login(BBL_CLOUD_PROVIDER))
            return false;
        wxGetApp().request_user_login(1, BBL_CLOUD_PROVIDER);
        return true;
    };
    hooks.detach = [] {
        NetworkAgent* agent = wxGetApp().getAgent();
        if (agent == nullptr)
            return;
        // Not request_user_logout(): that also ends the session on Bambu's side, and this account
        // stays saved to switch back to.
        if (wxGetApp().get_printer_cloud_provider() == BBL_CLOUD_PROVIDER) {
            agent->set_user_selected_machine("");
            if (DeviceManager* dev = wxGetApp().getDeviceManager())
                dev->clean_user_info(true);
        }
        agent->user_logout(false, BBL_CLOUD_PROVIDER);
        reset_bambu_cloud_list();
    };
    m_account_set = std::make_shared<CloudAccountSet>(BBL_CLOUD_PROVIDER, std::move(hooks));
}

void BambuCloudProvider::refresh_printers(PrintersCallback done)
{
    done = [done, others = m_others, set = m_account_set](std::vector<CloudPrinter> printers, wxString error) {
        printers = others->merge(std::move(printers), set, error);
        done(std::move(printers), error);
    };
    std::vector<CloudPrinter> printers;
    DeviceManager* dev   = wxGetApp().getDeviceManager();
    NetworkAgent*  agent = wxGetApp().getAgent();

    // The account's list (with each printer's online flag and job state), at most every 30 s,
    // off the GUI thread; the page refreshes when it arrives.
    const long long now = static_cast<long long>(Slic3r::Utils::get_current_time_utc());
    if (!is_logged_in()) {
        std::lock_guard<std::mutex> lock(s_bambu_mutex);
        s_bambu_cloud.clear();
        s_bambu_last_fetch = 0; // fetch right after the next login
    } else if (now - s_bambu_last_fetch.load() >= 30 && !s_bambu_fetching.exchange(true)) {
        s_bambu_last_fetch = now;
        std::shared_ptr<ICloudServiceAgent> cloud = agent != nullptr ? agent->get_cloud_agent(BBL_CLOUD_PROVIDER) : nullptr;
        if (cloud) {
            const std::string provider = id();
            std::thread([cloud, provider]() {
                unsigned int http_code = 0;
                std::string  body;
                try {
                    if (cloud->get_user_print_info(&http_code, &body) == 0)
                        parse_bambu_cloud_list(body);
                } catch (const std::exception& e) {
                    BOOST_LOG_TRIVIAL(warning) << "Device hub: Bambu printer list unreadable: " << e.what();
                }
                s_bambu_fetching = false;
                CloudPrinterProviders::notify_changed(provider);
            }).detach();
        } else {
            s_bambu_fetching = false;
        }
    }

    // What the live Bambu agent knows: LAN printers it discovered and the one it is connected to.
    std::map<std::string, MachineObject*> local, user;
    if (dev != nullptr) {
        local = dev->get_local_machinelist();
        user  = dev->get_user_machinelist();
    }
    auto is_bambu = [](const std::string& dev_id, const MachineObject* obj) {
        // The discovery list also holds every other brand's machines: the CC2 LAN plugin's
        // ("cc2-<ip>") and the one a non-Bambu preset's host creates (keyed by that address, e.g.
        // "10.0.0.45"). Bambu printers' ids are serial numbers, never addresses.
        if (obj == nullptr || dev_id.rfind("cc2-", 0) == 0 || dev_id.find_first_of(".:") != std::string::npos)
            return false;
        return obj->printer_agent_id.empty() || obj->printer_agent_id == BBL_PRINTER_AGENT_ID;
    };
    // LAN discovery repeats every few seconds while a printer is on, so an announcement older than
    // this means it is off (or the Bambu agent is not live to hear it).
    constexpr long long LAN_ALIVE_S = 60;

    std::map<std::string, BambuCloudPrinter> cloud;
    {
        std::lock_guard<std::mutex> lock(s_bambu_mutex);
        cloud = s_bambu_cloud;
    }
    std::set<std::string> ids;
    for (const auto& [dev_id, p] : cloud)
        ids.insert(dev_id);
    for (const auto* list : {&local, &user})
        for (const auto& [dev_id, obj] : *list)
            if (is_bambu(dev_id, obj))
                ids.insert(dev_id);

    for (const std::string& dev_id : ids) {
        auto           cloud_it = cloud.find(dev_id);
        MachineObject* lan      = local.count(dev_id) && is_bambu(dev_id, local[dev_id]) ? local[dev_id] : nullptr;
        MachineObject* bound    = user.count(dev_id) && is_bambu(dev_id, user[dev_id]) ? user[dev_id] : nullptr;
        MachineObject* obj      = bound != nullptr ? bound : lan;

        // MachineObject::is_online() alone is not the printer's state: a LAN printer saved from an
        // earlier session starts as "online" with no status at all, which listed switched-off
        // printers as Idle. Online means: reporting right now, online by the account's list, or
        // seen on the network a moment ago.
        const bool connected = obj != nullptr && obj->is_connected() && !obj->print_status.empty();
        const bool lan_alive = lan != nullptr && lan->last_alive > 0 && now - static_cast<long long>(lan->last_alive) < LAN_ALIVE_S;
        const bool online    = connected || lan_alive || (cloud_it != cloud.end() && cloud_it->second.online);

        CloudPrinter p;
        p.provider_id = id();
        p.id          = dev_id;
        if (obj != nullptr) {
            p.name  = from_u8(obj->get_dev_name());
            p.model = obj->get_printer_type_display_str();
            p.image = obj->printer_type;
        }
        if (cloud_it != cloud.end()) {
            if (p.name.empty())
                p.name = from_u8(cloud_it->second.name);
            if (p.model.empty())
                p.model = from_u8(cloud_it->second.model);
            if (p.image.empty())
                p.image = cloud_it->second.model_id;
        }
        if (!p.image.empty())
            p.image = "printer_preview_" + p.image;
        p.online = online;
        // The live report when connected, else the job the account reports; with neither the
        // printer is reachable but its state unknown, which is not the same as idle.
        const std::string status = connected ? obj->print_status : cloud_it != cloud.end() ? cloud_it->second.task_status : std::string();
        if (!online)
            p.status = _L("Offline");
        else if (!status.empty())
            p.status = print_status_text(status);
        else
            p.status = _L("Online");
        if (connected && (obj->print_status == "RUNNING" || obj->print_status == "PAUSE"))
            p.progress = obj->mc_print_percent;
        printers.push_back(std::move(p));
    }
    done(std::move(printers), {});
}

void BambuCloudProvider::open_printer(wxWindow* parent, const std::string& printer_id)
{
    // Monitored on the Printer page whatever printer preset is selected.
    if (!wxGetApp().monitor_printer(BBL_PRINTER_AGENT_ID, printer_id))
        MessageDialog(parent, unavailable_reason(), display_name(), wxOK | wxICON_INFORMATION).ShowModal();
}

bool BambuCloudProvider::handles_printer_preset(const DynamicPrintConfig& printer_config) const
{
    return effective_agent_id(printer_config) == BBL_PRINTER_AGENT_ID;
}

// ---------------------------------------------------------------------------------------------
// PrinterAgentCloudProvider
// ---------------------------------------------------------------------------------------------

namespace {

// Parses one discovery announcement (a printer agent's ssdp JSON) into a printer; false to skip it.
// Free of the provider so that the other-account fetch, which runs on a worker thread, never
// needs one.
bool parse_agent_announcement(const std::string& json, const std::string& agent_id, CloudPrinter& out)
{
    try {
        const nlohmann::json j = nlohmann::json::parse(json);
        out.id = j.value("dev_id", std::string());
        if (out.id.empty())
            return false;
        out.name  = from_u8(j.value("dev_name", out.id));
        out.model = from_u8(j.value("dev_type", std::string()));
        out.online = j.value("online", true);
        if (j.contains("status") && j["status"].is_string())
            out.status = from_u8(j["status"].get<std::string>());
        else
            out.status = out.online ? _L("Online") : _L("Offline");
        if (j.contains("progress") && j["progress"].is_number())
            out.progress = j["progress"].get<int>();
        return true;
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "Device hub: bad announcement from agent " << agent_id << ": " << e.what();
        return false;
    }
}

} // namespace

PrinterAgentCloudProvider::PrinterAgentCloudProvider(
    std::string provider_id, wxString display_name, int order, std::string agent_id, std::string cloud_provider, wxColour brand_colour)
    : m_id(std::move(provider_id))
    , m_name(std::move(display_name))
    , m_order(order)
    , m_agent_id(std::move(agent_id))
    , m_cloud_provider(std::move(cloud_provider))
    , m_brand(brand_colour)
{}

PrinterAgentCloudProvider::~PrinterAgentCloudProvider()
{
    if (m_agent) {
        m_agent->set_on_ssdp_msg_fn(nullptr);
        m_agent->start_discovery(false, false);
    }
}

bool PrinterAgentCloudProvider::is_available() const { return NetworkAgentFactory::is_printer_agent_registered(m_agent_id); }

wxString PrinterAgentCloudProvider::unavailable_reason() const
{
    // TRN %1% is a printer brand, e.g. "Elegoo".
    return format_wxstr(_L("The %1% printer connection is not installed or is turned off in the plug-in manager."), m_name);
}

std::string PrinterAgentCloudProvider::running_cloud_provider() const
{
    const std::string provider = m_cloud_provider.empty() ? NetworkAgentFactory::cloud_provider_for_agent(m_agent_id) : m_cloud_provider;
    // The Orca account is the fallback every agent gets; it is not this service's account.
    if (provider == ORCA_CLOUD_PROVIDER)
        return {};
    NetworkAgent* agent = wxGetApp().getAgent();
    return agent != nullptr && agent->get_cloud_agent(provider) != nullptr ? provider : std::string();
}

void PrinterAgentCloudProvider::clear_printers()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_seen.clear();
    }
    CloudPrinterProviders::notify_changed(m_id);
}

bool PrinterAgentCloudProvider::is_logged_in() const
{
    if (const std::string provider = running_cloud_provider(); !provider.empty())
        return wxGetApp().is_user_login(provider);
    std::lock_guard<std::mutex> lock(m_mutex);
    return !m_seen.empty();
}

wxString PrinterAgentCloudProvider::account_name() const
{
    const std::string provider = running_cloud_provider();
    if (provider.empty())
        return {};
    std::shared_ptr<ICloudServiceAgent> cloud = wxGetApp().getAgent()->get_cloud_agent(provider);
    if (!cloud || !cloud->is_user_login())
        return {};
    std::string name = cloud->get_user_nickname();
    if (name.empty())
        name = cloud->get_user_name();
    return from_u8(name);
}

void PrinterAgentCloudProvider::login(wxWindow* parent)
{
    if (const std::string provider = running_cloud_provider(); !provider.empty()) {
        wxGetApp().request_login(true, provider);
        clear_printers();
        return;
    }
    // TRN %1% is a printer brand, e.g. "Elegoo".
    MessageDialog(parent,
                  format_wxstr(_L("Select a %1% printer preset and connect to it on the Printer page. Its printers then show up here."), m_name),
                  m_name, wxOK | wxICON_INFORMATION)
        .ShowModal();
}

void PrinterAgentCloudProvider::logout()
{
    if (const std::string provider = running_cloud_provider(); !provider.empty())
        wxGetApp().request_user_logout(provider, true);
    clear_printers();
}

std::shared_ptr<IPrinterAgent> PrinterAgentCloudProvider::ensure_agent()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_agent)
        return m_agent;

    // Straight from the factory, not create_printer_agent_by_id(): that returns the cached
    // instance the app may be using, and setting our discovery callback on it would steal its
    // announcements.
    PrinterAgentFactory factory;
    if (const PrinterAgentInfo* info = NetworkAgentFactory::get_printer_agent_info(m_agent_id))
        factory = info->factory;
    if (!factory)
        return nullptr;

    std::shared_ptr<ICloudServiceAgent> cloud;
    if (NetworkAgent* app_agent = wxGetApp().getAgent()) {
        cloud = app_agent->get_cloud_agent(NetworkAgentFactory::cloud_provider_for_agent(m_agent_id));
        if (!cloud)
            cloud = app_agent->get_cloud_agent(ORCA_CLOUD_PROVIDER);
    }
    m_agent = factory(cloud, data_dir());
    if (!m_agent)
        return nullptr;

    m_agent->set_queue_on_main_fn([](std::function<void()> fn) { wxGetApp().CallAfter(std::move(fn)); });
    m_agent->set_on_ssdp_msg_fn([this](std::string json) {
        CloudPrinter p;
        if (!parse_agent_announcement(json, m_agent_id, p))
            return;
        p.provider_id = m_id;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            auto it = m_seen.find(p.id);
            // Only news is announced: every refresh re-runs discovery, and a notification
            // refreshes the page, so repeating unchanged devices would loop.
            if (it != m_seen.end() && it->second.name == p.name && it->second.model == p.model &&
                it->second.status == p.status && it->second.online == p.online && it->second.progress == p.progress)
                return;
            m_seen[p.id] = std::move(p);
        }
        CloudPrinterProviders::notify_changed(m_id);
    });
    return m_agent;
}

void PrinterAgentCloudProvider::refresh_printers(PrintersCallback done)
{
    if (std::shared_ptr<IPrinterAgent> agent = ensure_agent())
        agent->start_discovery(true, false);

    // Announcements arrive asynchronously and re-notify; report what is known now.
    std::vector<CloudPrinter> printers;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (const auto& [printer_id, printer] : m_seen)
            printers.push_back(printer);
    }
    done(std::move(printers), {});
}

void PrinterAgentCloudProvider::open_printer(wxWindow* parent, const std::string& printer_id)
{
    // The printer's own agent drives the Printer page, whatever printer preset is selected.
    if (!wxGetApp().monitor_printer(m_agent_id, printer_id))
        login(parent);
}

bool PrinterAgentCloudProvider::handles_printer_preset(const DynamicPrintConfig& printer_config) const
{
    return effective_agent_id(printer_config) == m_agent_id;
}

// ---------------------------------------------------------------------------------------------
// CrealityCloudProvider
// ---------------------------------------------------------------------------------------------

namespace {

nlohmann::json creality_session_json(const CrealityCloud::Session& s)
{
    return {{"user_id", s.user_id}, {"token", s.token}, {"nickname", s.nickname}, {"avatar", s.avatar},
            {"region", CrealityCloud::region_to_string(s.region)}};
}

CrealityCloud::Session creality_session(const nlohmann::json& j)
{
    CrealityCloud::Session s;
    s.user_id  = j.value("user_id", std::string());
    s.token    = j.value("token", std::string());
    s.nickname = j.value("nickname", std::string());
    s.avatar   = j.value("avatar", std::string());
    s.region   = CrealityCloud::region_from_string(j.value("region", std::string()));
    return s;
}

} // namespace

CrealityCloudProvider::CrealityCloudProvider()
    : PrinterAgentCloudProvider("creality", "Creality", 30, "creality_cloud", "creality", wxColour("#D8762C"))
{
    namespace CC = CrealityCloud;
    // The printers of another saved account, as the agent would announce them.
    m_others = std::make_shared<OtherAccountPrinters>(id(), [agent = agent_id()](nlohmann::json& data) {
        std::vector<CC::Device> devices;
        std::string             error;
        const int               code = CC::Client(creality_session(data)).list_devices(devices, error);
        if (code == CC::CODE_TOKEN_INVALID)
            throw std::runtime_error(_u8L("Signed out. Sign in to this account again on the Accounts tab."));
        if (code != CC::CODE_OK)
            throw std::runtime_error(error.empty() ? _u8L("Could not reach Creality Cloud.") : error);
        std::vector<CloudPrinter> out;
        for (const CC::Device& d : devices) {
            CloudPrinter p;
            if (parse_agent_announcement(CC::ssdp_payload(d).dump(), agent, p))
                out.push_back(std::move(p));
        }
        return out;
    });
    CloudAccountSet::Hooks hooks;
    hooks.active_key   = [] { const CC::Session s = CC::SessionStore::get(); return s.valid() ? s.user_id : std::string(); };
    hooks.active_label = [] { const CC::Session s = CC::SessionStore::get(); return s.nickname.empty() ? s.user_id : s.nickname; };
    hooks.capture      = []() -> nlohmann::json { return creality_session_json(CC::SessionStore::get()); };
    hooks.apply        = [this](const nlohmann::json& data) {
        const CC::Session s = creality_session(data);
        if (!s.valid())
            return false;
        CC::SessionStore::set(s);
        clear_printers();
        m_others->invalidate();
        return true;
    };
    // The session lives only in the app's file; dropping it here leaves it valid on the server.
    hooks.detach  = [this] {
        CC::SessionStore::clear();
        clear_printers();
    };
    m_account_set = std::make_shared<CloudAccountSet>(id(), std::move(hooks));
}

void CrealityCloudProvider::refresh_printers(PrintersCallback done)
{
    PrinterAgentCloudProvider::refresh_printers([&](std::vector<CloudPrinter> printers, wxString error) {
        printers = m_others->merge(std::move(printers), m_account_set, error);
        done(std::move(printers), error);
    });
}

// ---------------------------------------------------------------------------------------------
// MarkforgedCloudProvider
// ---------------------------------------------------------------------------------------------

namespace {

// The API keys live in the file the Markforged agent plug-in shares; Eiger keeps the secret protected.
nlohmann::json read_markforged_settings() { return Eiger::read_settings(); }
bool write_markforged_settings(const nlohmann::json& settings) { return Eiger::write_settings(settings); }

} // namespace

MarkforgedCloudProvider::MarkforgedCloudProvider() : PrinterAgentCloudProvider("markforged", "Markforged", 40, "markforged_eiger", {}, wxColour("#8B8F95"))
{
    // Each key pair is an account (an Eiger organisation); the others' printers come from Eiger directly.
    m_others = std::make_shared<OtherAccountPrinters>(id(), [](nlohmann::json& data) {
        std::vector<CloudPrinter> out;
        for (const nlohmann::json& d : Eiger({data.value("access_key", std::string()), data.value("secret_key", std::string())}).devices()) {
            auto str = [&d](const char* key) { return d.contains(key) && d[key].is_string() ? d[key].get<std::string>() : std::string(); };
            CloudPrinter p;
            p.id = str("id");
            if (p.id.empty())
                continue;
            p.name                  = from_u8(str("name").empty() ? p.id : str("name"));
            p.model                 = from_u8(str("device_type"));
            const std::string state = str("state");
            p.online                = !(state.empty() || state == "Offline" || state == "Disabled" || state == "Unknown");
            p.status                = p.online ? from_u8(state) : _L("Offline");
            out.push_back(std::move(p));
        }
        return out;
    });
    CloudAccountSet::Hooks hooks;
    hooks.active_key   = [] { return Eiger::has_keys() ? read_markforged_settings().value("access_key", std::string()) : std::string(); };
    hooks.active_label = [this] { return into_u8(account_name()); };
    hooks.capture      = []() -> nlohmann::json {
        const nlohmann::json s = read_markforged_settings();
        return {{"access_key", s.value("access_key", std::string())}, {"secret_key", s.value("secret_key", std::string())}};
    };
    hooks.apply = [this](const nlohmann::json& data) {
        nlohmann::json settings = read_markforged_settings();
        if (!settings.is_object())
            settings = nlohmann::json::object();
        settings["access_key"] = data.value("access_key", std::string());
        settings["secret_key"] = data.value("secret_key", std::string());
        const bool ok          = write_markforged_settings(settings);
        clear_printers();
        m_others->invalidate();
        return ok;
    };
    hooks.detach  = [this] { logout(); };
    m_account_set = std::make_shared<CloudAccountSet>(id(), std::move(hooks));
}

void MarkforgedCloudProvider::refresh_printers(PrintersCallback done)
{
    PrinterAgentCloudProvider::refresh_printers([&](std::vector<CloudPrinter> printers, wxString error) {
        printers = m_others->merge(std::move(printers), m_account_set, error);
        done(std::move(printers), error);
    });
}

bool MarkforgedCloudProvider::is_logged_in() const { return Eiger::has_keys(); }

void MarkforgedCloudProvider::login(wxWindow* parent)
{
    wxDialog dlg(parent, wxID_ANY, _L("Markforged account"));
    auto* sizer = new wxBoxSizer(wxVERTICAL);
    auto* intro = new wxStaticText(&dlg, wxID_ANY,
                                   _L("Enter an Eiger API key pair. Create one in Eiger under Settings > API keys."));
    intro->Wrap(dlg.FromDIP(380));
    sizer->Add(intro, 0, wxALL, dlg.FromDIP(12));

    auto* grid = new wxFlexGridSizer(2, dlg.FromDIP(8), dlg.FromDIP(8));
    grid->AddGrowableCol(1);
    auto* access = new wxTextCtrl(&dlg, wxID_ANY, wxEmptyString, wxDefaultPosition, wxSize(dlg.FromDIP(260), -1));
    auto* secret = new wxTextCtrl(&dlg, wxID_ANY, wxEmptyString, wxDefaultPosition, wxSize(dlg.FromDIP(260), -1), wxTE_PASSWORD);
    grid->Add(new wxStaticText(&dlg, wxID_ANY, _L("Access key")), 0, wxALIGN_CENTER_VERTICAL);
    grid->Add(access, 1, wxEXPAND);
    grid->Add(new wxStaticText(&dlg, wxID_ANY, _L("Secret key")), 0, wxALIGN_CENTER_VERTICAL);
    grid->Add(secret, 1, wxEXPAND);
    sizer->Add(grid, 0, wxEXPAND | wxLEFT | wxRIGHT, dlg.FromDIP(12));

    if (wxSizer* buttons = dlg.CreateStdDialogButtonSizer(wxOK | wxCANCEL))
        sizer->Add(buttons, 0, wxEXPAND | wxALL, dlg.FromDIP(12));
    dlg.SetSizerAndFit(sizer);

    if (dlg.ShowModal() != wxID_OK)
        return;
    const std::string access_key = into_u8(access->GetValue().Strip(wxString::both));
    const std::string secret_key = into_u8(secret->GetValue().Strip(wxString::both));
    if (access_key.empty() || secret_key.empty())
        return;

    // Check the keys before keeping them, so a typo shows up here and not as an empty printer list.
    try {
        run_busy(parent, display_name(), _L("Checking the API keys…"), [&] { Eiger({access_key, secret_key}).devices(); });
    } catch (const std::exception& e) {
        MessageDialog(parent, wxString::FromUTF8(e.what()), display_name(), wxOK | wxICON_ERROR).ShowModal();
        return;
    }

    // Merge: the plug-in keeps its own settings in the same file.
    nlohmann::json settings = read_markforged_settings();
    if (!settings.is_object())
        settings = nlohmann::json::object();
    settings["access_key"] = access_key;
    settings["secret_key"] = secret_key;
    if (!write_markforged_settings(settings))
        MessageDialog(parent, _L("The API keys could not be saved."), display_name(), wxOK | wxICON_ERROR).ShowModal();
    clear_printers();
}

wxString MarkforgedCloudProvider::account_name() const
{
    const std::string key = read_markforged_settings().value("access_key", std::string());
    if (key.empty())
        return {};
    // TRN %1% is the last characters of an Eiger API access key.
    return format_wxstr(_L("API key …%1%"), key.size() > 4 ? key.substr(key.size() - 4) : key);
}

void MarkforgedCloudProvider::logout()
{
    nlohmann::json settings = read_markforged_settings();
    if (settings.is_object()) {
        settings.erase("access_key");
        settings.erase("secret_key");
        write_markforged_settings(settings);
    }
    clear_printers();
}

// ---------------------------------------------------------------------------------------------
// ElegooCloudProvider
// ---------------------------------------------------------------------------------------------


bool ElegooCloudProvider::is_logged_in() const { return ElegooCloud::instance().signed_in(); }

wxString ElegooCloudProvider::account_name() const
{
    return wxString::FromUTF8(ElegooCloud::instance().account_label());
}

void ElegooCloudProvider::login(wxWindow* parent) { ElegooLoginDialog::sign_in(parent); }

void ElegooCloudProvider::logout()
{
    ElegooCloud::instance().sign_out();
    clear_printers();
}

wxWindow* ElegooCloudProvider::create_page(wxWindow* parent)
{
    auto* page = new ElegooDevicePage(parent);
    page->set_list_page(new CloudProviderPage(page->book(), CloudPrinterProviders::get(id())));
    return page;
}

// The account's printers from the last cloud answer, shown while a new one is on its way.
static std::mutex                s_elegoo_cloud_mutex;
static std::vector<CloudPrinter> s_elegoo_cloud_printers;

// A printer of the account (keyed by serial) opens ElegooSlicer's cloud printer page on the Elegoo
// page of the Device tab, like a Bambu cloud printer opens the Device tab. A printer found on this network ("cc2-<ip>") opens its own web page on
// the Device tab, which talks to it directly. The generic agent provider fell back to login()
// here, so a double-click asked for the Elegoo sign-in again and never opened anything.
void ElegooCloudProvider::open_printer(wxWindow* parent, const std::string& printer_id)
{
    const std::string ip = printer_id.rfind("cc2-", 0) == 0 ? printer_id.substr(4) : std::string();
    if (ip.empty()) {
        if (!ElegooCloud::instance().signed_in()) {
            login(parent);
            if (!ElegooCloud::instance().signed_in())
                return;
        }
        wxString name;
        {
            std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
            for (const CloudPrinter& p : s_elegoo_cloud_printers)
                if (p.id == printer_id)
                    name = p.name;
        }
        show_elegoo_cloud_monitor(parent, printer_id, name);
        return;
    }
    if (const PresetBundle* bundle = wxGetApp().preset_bundle; bundle != nullptr) {
        const DynamicPrintConfig& cfg = bundle->printers.get_edited_preset().config;
        const auto*               ht  = cfg.option<ConfigOptionEnum<PrintHostType>>("host_type");
        const bool                has_host = cfg.has("print_host") && !cfg.opt_string("print_host").empty();
        // An Elegoo preset: its own address, else the one this printer was discovered at.
        if ((ht != nullptr && ht->value == htElegooLink && (has_host || !ip.empty())) || handles_printer_preset(cfg)) {
            if (MainFrame* frame = wxGetApp().mainframe; frame != nullptr && frame->open_printer_web_ui(ip))
                return;
        }
    }
    wxString text = _L("To control this printer here, select your Elegoo printer preset and enter the printer's IP address in "
                       "its connection settings. Its page then opens on the Device tab.");
    text += "\n\n" + format_wxstr(_L("Open the printer's page (%1%) in your web browser now?"), ip);
    if (MessageDialog(parent, text, display_name(), wxYES_NO | wxICON_QUESTION).ShowModal() == wxID_YES)
        wxLaunchDefaultBrowser(wxString::FromUTF8("http://" + ip));
}

// One account fetch at a time: the page polls every few seconds, and on a slow connection a
// fetch outlasts that; overlapping fetches would pile up and could answer out of order.
static std::atomic<bool>         s_elegoo_cloud_fetching{false};

namespace {

nlohmann::json elegoo_account_json(const ElegooCloudAccount& a)
{
    return {{"region", a.region},   {"access_token", a.access_token}, {"refresh_token", a.refresh_token}, {"access_expire_ms", a.access_expire_ms},
            {"user_id", a.user_id}, {"nickname", a.nickname},         {"email", a.email},                 {"avatar", a.avatar}};
}

ElegooCloudAccount elegoo_account(const nlohmann::json& j)
{
    ElegooCloudAccount a;
    a.region           = j.value("region", std::string("global"));
    a.access_token     = j.value("access_token", std::string());
    a.refresh_token    = j.value("refresh_token", std::string());
    a.access_expire_ms = j.value("access_expire_ms", int64_t(0));
    a.user_id          = j.value("user_id", std::string());
    a.nickname         = j.value("nickname", std::string());
    a.email            = j.value("email", std::string());
    a.avatar           = j.value("avatar", std::string());
    return a;
}

std::string elegoo_account_key(const ElegooCloudAccount& a) { return a.user_id.empty() ? a.email : a.user_id; }

// One account's printers with their online state and status, through `cloud`. Blocking.
std::vector<CloudPrinter> elegoo_printers(ElegooCloud& cloud, const std::string& provider)
{
    std::vector<CloudPrinter> out;
    for (const ElegooCloudPrinter& p : cloud.printers()) {
        // The device list carries no status. The report data does (1 idle, 2 printing), but it
        // keeps the last state after the printer goes offline, so ask for the online state first.
        const int    online = cloud.printer_online(p.serial);
        const int    state  = online == 0 ? -1 : cloud.printer_state(p.serial);
        CloudPrinter cp;
        cp.provider_id = provider;
        cp.id          = p.serial;
        cp.name        = wxString::FromUTF8(p.name.empty() ? p.serial : p.name);
        cp.model       = wxString::FromUTF8(p.model);
        cp.online      = online != 0 && state >= 0;
        cp.status      = online == 0 ? _L("Offline") : state == 2 ? _L("Printing") : state == 1 ? _L("Idle") : _L("Unknown");
        out.push_back(std::move(cp));
    }
    return out;
}

} // namespace

ElegooCloudProvider::ElegooCloudProvider()
    : PrinterAgentCloudProvider(ELEGOO_CLOUD_PROVIDER, "Elegoo", 20, "elegoo_cc2", {}, wxColour("#3A6FD8"))
{
    const std::string provider = id();
    // Another saved account's printers, with its own tokens; refreshed tokens go back to `data`.
    m_others = std::make_shared<OtherAccountPrinters>(provider, [provider](nlohmann::json& data) {
        std::unique_ptr<ElegooCloud> cloud = ElegooCloud::for_account(elegoo_account(data));
        std::vector<CloudPrinter>    out;
        try {
            out = elegoo_printers(*cloud, provider);
        } catch (...) {
            data = elegoo_account_json(cloud->account());
            throw;
        }
        data = elegoo_account_json(cloud->account());
        return out;
    });
    CloudAccountSet::Hooks hooks;
    hooks.active_key = [] {
        ElegooCloud& cloud = ElegooCloud::instance();
        return cloud.signed_in() ? elegoo_account_key(cloud.account()) : std::string();
    };
    hooks.active_label = [] { return ElegooCloud::instance().account_label(); };
    hooks.capture      = []() -> nlohmann::json { return elegoo_account_json(ElegooCloud::instance().account()); };
    hooks.apply        = [this](const nlohmann::json& data) {
        const ElegooCloudAccount account = elegoo_account(data);
        if (account.access_token.empty())
            return false;
        ElegooCloud::instance().set_account(account);
        {
            std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
            s_elegoo_cloud_printers.clear();
        }
        clear_printers();
        m_others->invalidate();
        return true;
    };
    // Local only: ElegooCloud::sign_out() forgets the tokens without ending the session on Elegoo's
    // side. The messaging session belongs to the account, so it is closed too.
    hooks.detach = [] {
        ElegooCloud::close_live_session_later();
        ElegooCloud::instance().sign_out();
    };
    m_account_set = std::make_shared<CloudAccountSet>(provider, std::move(hooks));
}

static std::vector<CloudPrinter> merge_lan(std::vector<CloudPrinter> out, const std::vector<CloudPrinter>& lan)
{
    // A LAN printer the account also lists shows once (the cloud entry, keyed by serial).
    for (const CloudPrinter& p : lan) {
        bool dup = false;
        for (const CloudPrinter& c : out)
            if (c.id == p.id) { dup = true; break; }
        if (!dup)
            out.push_back(p);
    }
    return out;
}

void ElegooCloudProvider::refresh_printers(PrintersCallback done)
{
    done = [done, others = m_others, set = m_account_set](std::vector<CloudPrinter> printers, wxString error) {
        printers = others->merge(std::move(printers), set, error);
        done(std::move(printers), error);
    };
    // Printers on the local network, from the LAN agent.
    std::vector<CloudPrinter> lan;
    PrinterAgentCloudProvider::refresh_printers([&lan](std::vector<CloudPrinter> printers, wxString) { lan = std::move(printers); });
    if (!ElegooCloud::instance().signed_in()) {
        done(std::move(lan), {});
        return;
    }
    // Show the LAN printers (and the last known cloud ones) right away: the cloud call can take
    // up to a connect timeout per request when the internet is slow or down.
    {
        std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
        done(merge_lan(s_elegoo_cloud_printers, lan), {});
    }
    if (s_elegoo_cloud_fetching.exchange(true))
        return; // the fetch in flight answers with fresh data
    // The account's printers: blocking HTTPS, so off the GUI thread (the caller marshals the callback).
    const std::string provider = id();
    const std::string account  = elegoo_account_key(ElegooCloud::instance().account());
    std::thread([done, lan = std::move(lan), provider, account]() {
        std::vector<CloudPrinter> out;
        wxString                  error;
        try {
            out = elegoo_printers(ElegooCloud::instance(), provider);
            std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
            // Another account became active meanwhile: these are no longer its printers.
            if (account != elegoo_account_key(ElegooCloud::instance().account())) {
                s_elegoo_cloud_fetching = false;
                return;
            }
            s_elegoo_cloud_printers = out;
        } catch (const ElegooAuthError& ex) {
            error = wxString::FromUTF8(ex.what());
            std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
            s_elegoo_cloud_printers.clear();
        } catch (const std::exception& ex) {
            // Offline or the cloud is slow: keep the last known account printers, marked unreachable.
            error = _L("Could not reach the Elegoo cloud. Check the internet connection; printers on this network still work.") +
                    "\n" + wxString::FromUTF8(ex.what());
            std::lock_guard<std::mutex> lock(s_elegoo_cloud_mutex);
            out = s_elegoo_cloud_printers;
            for (CloudPrinter& c : out) {
                c.online = false;
                c.status = _L("Unknown");
            }
        }
        s_elegoo_cloud_fetching = false;
        done(merge_lan(std::move(out), lan), error);
    }).detach();
}
}} // namespace Slic3r::GUI
