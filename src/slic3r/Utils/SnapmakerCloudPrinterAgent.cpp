#include "SnapmakerCloudPrinterAgent.hpp"

#include "ICloudServiceAgent.hpp"
#include "MoonrakerPrinterAgent.hpp"
#include "IPrinterAgent.hpp"
#include "SnapmakerCloud.hpp"
#include "bambu_networking.hpp"
#include "slic3r/GUI/GUI_App.hpp"
#include "slic3r/GUI/I18N.hpp"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>

namespace Slic3r {

using nlohmann::json;
namespace SC = SnapmakerCloud;

namespace {

constexpr const char* AGENT_VERSION = "1.0.0";
constexpr auto        DISCOVERY_INTERVAL = std::chrono::seconds(15);
constexpr auto        STATUS_INTERVAL    = std::chrono::seconds(5);
constexpr auto        OFFLINE_INTERVAL   = std::chrono::seconds(15);

// Sleeps in short steps so a stop request does not wait out the interval.
template<class Stop> void wait_for(std::chrono::milliseconds total, Stop stop)
{
    const auto step = std::chrono::milliseconds(100);
    for (auto waited = std::chrono::milliseconds(0); waited < total && !stop(); waited += step)
        std::this_thread::sleep_for(step);
}

// The file name a print is stored under on the printer.
std::string file_name(const PrintParams& params, const std::string& gcode_path)
{
    std::string name = !params.task_name.empty() ? params.task_name :
                       !params.project_name.empty() ? params.project_name :
                                                      boost::filesystem::path(gcode_path).stem().string();
    for (const char* extension : {".3mf", ".gcode"})
        if (boost::iends_with(name, extension))
            name.erase(name.size() - std::strlen(extension));
    return (name.empty() ? std::string("print") : name) + ".gcode";
}

// The Moonraker objects the status poll asks for.
const nlohmann::json& status_query()
{
    static const nlohmann::json q = {{"objects",
                                      {{"print_stats", nullptr}, {"display_status", nullptr}, {"extruder", nullptr}, {"heater_bed", nullptr}}}};
    return q;
}

} // namespace

SnapmakerCloudPrinterAgent::SnapmakerCloudPrinterAgent(std::string log_dir) : m_log_dir(std::move(log_dir)) {}

SnapmakerCloudPrinterAgent::~SnapmakerCloudPrinterAgent()
{
    stop_discovery();
    stop_status(true);
    std::lock_guard<std::mutex> lock(m_link_mutex);
    m_link.reset();
}

AgentInfo SnapmakerCloudPrinterAgent::get_agent_info_static()
{
    return AgentInfo{AGENT_ID, "Snapmaker Cloud", AGENT_VERSION, "Print to Snapmaker printers through a Snapmaker account"};
}

void SnapmakerCloudPrinterAgent::set_cloud_agent(std::shared_ptr<ICloudServiceAgent> cloud)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_cloud_agent = std::move(cloud);
}

// --- Callbacks ----------------------------------------------------------------------------------

void SnapmakerCloudPrinterAgent::post(std::function<void()> fn)
{
    QueueOnMainFn queue;
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        queue = m_queue_on_main;
    }
    if (queue)
        queue(std::move(fn));
    else
        fn();
}

void SnapmakerCloudPrinterAgent::dispatch_message(const std::string& dev_id, const std::string& payload)
{
    OnMessageFn local, cloud;
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        local = m_on_local_message;
        cloud = m_on_message;
    }
    if (!local && !cloud)
        return;
    post([dev_id, payload, local, cloud]() {
        if (local)
            local(dev_id, payload);
        else
            cloud(dev_id, payload);
    });
}

int SnapmakerCloudPrinterAgent::set_on_ssdp_msg_fn(OnMsgArrivedFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_ssdp = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_printer_connected_fn(OnPrinterConnectedFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_printer_connected = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_subscribe_failure_fn(GetSubscribeFailureFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_subscribe_failure = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_message_fn(OnMessageFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_message = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_user_message_fn(OnMessageFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_user_message = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_local_connect_fn(OnLocalConnectedFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_local_connect = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_on_local_message_fn(OnMessageFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_local_message = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_queue_on_main_fn(QueueOnMainFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_queue_on_main = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}
int SnapmakerCloudPrinterAgent::set_server_callback(OnServerErrFn fn)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_on_server_err = std::move(fn);
    return BAMBU_NETWORK_SUCCESS;
}

std::string SnapmakerCloudPrinterAgent::get_user_selected_machine()
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    return m_selected;
}

int SnapmakerCloudPrinterAgent::set_user_selected_machine(std::string dev_id)
{
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_selected = std::move(dev_id);
    return BAMBU_NETWORK_SUCCESS;
}

// --- Discovery ----------------------------------------------------------------------------------

bool SnapmakerCloudPrinterAgent::start_discovery(bool start, bool /*sending*/)
{
    if (!start) {
        stop_discovery();
        return true;
    }
    if (!m_discovery_stop.exchange(false))
        return true; // Already running
    if (m_discovery_thread.joinable())
        m_discovery_thread.join();
    m_discovery_thread = std::thread([this] { discovery_loop(); });
    return true;
}

void SnapmakerCloudPrinterAgent::stop_discovery()
{
    m_discovery_stop.store(true);
    if (m_discovery_thread.joinable() && m_discovery_thread.get_id() != std::this_thread::get_id())
        m_discovery_thread.join();
}

void SnapmakerCloudPrinterAgent::discovery_loop()
{
    while (!m_discovery_stop.load()) {
        const SC::Session session = SC::SessionStore::get();
        if (session.valid()) {
            std::vector<SC::Device> devices;
            std::string             error;
            const int               code = SC::Client(session).list_devices(devices, error);
            if (code == SC::CODE_OK) {
                OnMsgArrivedFn ssdp;
                {
                    std::lock_guard<std::recursive_mutex> lock(m_mutex);
                    m_devices.clear();
                    for (const SC::Device& d : devices)
                        m_devices[d.sn] = d;
                    ssdp = m_on_ssdp;
                }
                if (ssdp)
                    for (const SC::Device& d : devices) {
                        const std::string payload = SC::ssdp_payload(d).dump();
                        post([ssdp, payload] { ssdp(payload); });
                    }
            } else {
                BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: listing printers failed (" << code << "): " << error;
            }
        }
        wait_for(DISCOVERY_INTERVAL, [this] { return m_discovery_stop.load(); });
    }
}

bool SnapmakerCloudPrinterAgent::find_device(const std::string& sn, SC::Device& device)
{
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        auto it = m_devices.find(sn);
        if (it != m_devices.end()) {
            device = it->second;
            return true;
        }
    }
    std::vector<SC::Device> devices;
    std::string             error;
    if (SC::Client(SC::SessionStore::get()).list_devices(devices, error) != SC::CODE_OK)
        return false;
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    for (const SC::Device& d : devices)
        m_devices[d.sn] = d;
    auto it = m_devices.find(sn);
    if (it == m_devices.end())
        return false;
    device = it->second;
    return true;
}

// --- Connection and status ----------------------------------------------------------------------

int SnapmakerCloudPrinterAgent::connect_printer(const PrinterConnectionParams& params)
{
    if (params.dev_id.empty())
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    stop_status();
    set_user_selected_machine(params.dev_id);
    const uint64_t generation = ++m_status_generation;
    m_status_thread           = std::thread([this, dev_id = params.dev_id, generation] { status_loop(dev_id, generation); });
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudPrinterAgent::disconnect_printer()
{
    stop_status();
    return BAMBU_NETWORK_SUCCESS;
}

void SnapmakerCloudPrinterAgent::stop_status(bool wait)
{
    ++m_status_generation;
    if (m_status_thread.joinable() && m_status_thread.get_id() != std::this_thread::get_id())
        m_retired_status_threads.push_back(std::move(m_status_thread));
    if (wait) {
        for (std::thread& t : m_retired_status_threads)
            if (t.joinable() && t.get_id() != std::this_thread::get_id())
                t.join();
        m_retired_status_threads.clear();
    }
}

int SnapmakerCloudPrinterAgent::rpc(const std::string& dev_id, const json& request, json& reply, std::chrono::milliseconds timeout, std::string& error)
{
    SC::Device device;
    if (!find_device(dev_id, device)) {
        error = "the printer is not on this Snapmaker account";
        return SC::CODE_PRINTER;
    }
    std::lock_guard<std::mutex> lock(m_link_mutex);
    if (!m_link || m_link_sn != dev_id || !m_link->is_open()) {
        m_link.reset();
        SC::MqttCert cert;
        const int    code = SC::Client(SC::SessionStore::get()).mqtt_cert(cert, error);
        if (code != SC::CODE_OK)
            return code;
        m_link    = std::make_unique<SC::PrinterLink>(device, cert);
        m_link_sn = dev_id;
    }
    return m_link->request(request, reply, timeout, error);
}

void SnapmakerCloudPrinterAgent::status_loop(std::string dev_id, uint64_t generation)
{
    auto stale     = [this, generation] { return generation != m_status_generation.load(); };
    bool connected = false;
    while (!stale()) {
        const SC::Session session = SC::SessionStore::get();
        SC::Device        device;
        // Refresh the device record each round, since it carries the online flag.
        {
            std::lock_guard<std::recursive_mutex> lock(m_mutex);
            m_devices.erase(dev_id);
        }
        if (session.valid() && find_device(dev_id, device)) {
            json status = json::object();
            if (device.online) {
                std::string error;
                if (rpc(dev_id, SC::rpc_request(0, "printer.objects.query", status_query()), status, std::chrono::seconds(10), error) != SC::CODE_OK)
                    BOOST_LOG_TRIVIAL(info) << "SnapmakerCloud: status of " << dev_id << " not available: " << error;
            }
            if (stale())
                break;
            if (!connected) {
                connected = true;
                OnLocalConnectedFn   local;
                OnPrinterConnectedFn printer;
                {
                    std::lock_guard<std::recursive_mutex> lock(m_mutex);
                    local   = m_on_local_connect;
                    printer = m_on_printer_connected;
                }
                if (local)
                    post([local, dev_id] { local(ConnectStatusOk, dev_id, "0"); });
                if (printer)
                    post([printer, dev_id] { printer(dev_id); });
            }
            dispatch_message(dev_id, SC::status_payload(device, status).dump());
        }
        wait_for(device.online ? STATUS_INTERVAL : OFFLINE_INTERVAL, stale);
    }
}

int SnapmakerCloudPrinterAgent::send_message(std::string dev_id, std::string json_str, int qos, int flag)
{
    return send_message_to_printer(std::move(dev_id), std::move(json_str), qos, flag);
}

int SnapmakerCloudPrinterAgent::control(const std::string& dev_id, const std::string& method, const json& params)
{
    json        reply;
    std::string error;
    const int   code = rpc(dev_id, SC::rpc_request(0, method, params), reply, std::chrono::seconds(20), error);
    if (code != SC::CODE_OK)
        BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: " << method << " failed (" << code << "): " << error;
    return code == SC::CODE_OK ? BAMBU_NETWORK_SUCCESS : BAMBU_NETWORK_ERR_INVALID_HANDLE;
}

int SnapmakerCloudPrinterAgent::send_message_to_printer(std::string dev_id, std::string json_str, int /*qos*/, int /*flag*/)
{
    const json request = json::parse(json_str, nullptr, false);
    if (!request.is_object())
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;

    if (request.contains("info") && request["info"].value("command", "") == "get_version") {
        json reply;
        reply["info"]["command"] = "get_version";
        reply["info"]["result"]  = "success";
        reply["info"]["module"]  = json::array({json{{"name", "ota"}, {"sw_ver", ""}, {"product_name", "Snapmaker"}}});
        dispatch_message(dev_id, reply.dump());
        return BAMBU_NETWORK_SUCCESS;
    }
    if (!request.contains("print") || !request["print"].is_object())
        return BAMBU_NETWORK_SUCCESS;

    // The device panels speak Bambu's commands; the U1 runs Moonraker.
    const json&       print   = request["print"];
    const std::string command = print.value("command", "");
    if (command == "pause")
        return control(dev_id, "printer.print.pause");
    if (command == "resume")
        return control(dev_id, "printer.print.resume");
    if (command == "stop")
        return control(dev_id, "printer.print.cancel");
    if (command == "gcode_line" && print.contains("param") && print["param"].is_string())
        return control(dev_id, "printer.gcode.script", {{"script", print["param"].get<std::string>()}});
    if (command == "set_bed_temp" && print.contains("temp") && print["temp"].is_number())
        return control(dev_id, "printer.gcode.script", {{"script", "M140 S" + std::to_string(print["temp"].get<int>())}});
    if (command == "set_nozzle_temp" && print.contains("target_temp") && print["target_temp"].is_number())
        return control(dev_id, "printer.gcode.script", {{"script", "M104 S" + std::to_string(print["target_temp"].get<int>())}});
    return BAMBU_NETWORK_SUCCESS;
}

// --- Printing -----------------------------------------------------------------------------------

int SnapmakerCloudPrinterAgent::cloud_print(const PrintParams& params, bool start, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn)
{
    auto update = [&](int stage, int code, const std::string& msg) {
        if (update_fn)
            update_fn(stage, code, msg);
    };
    update(PrintingStageCreate, 0, _u8L("Preparing..."));

    const SC::Session session = SC::SessionStore::get();
    if (!session.valid()) {
        update(PrintingStageERROR, 0, _u8L("Sign in to Snapmaker first."));
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }

    // params.filename may be the .gcode.3mf bundle; dst_file, when set, is the plate's plain G-code.
    std::string gcode_path = !params.dst_file.empty() ? params.dst_file : params.filename;
    boost::filesystem::path extracted;
    if (boost::iends_with(gcode_path, ".3mf")) {
        boost::system::error_code ec;
        extracted = boost::filesystem::temp_directory_path(ec) / boost::filesystem::unique_path("snapmaker-plate-%%%%-%%%%.gcode", ec);
        if (ec || !MoonrakerPrinterAgent::extract_plate_gcode(gcode_path, params.plate_index, extracted)) {
            BOOST_LOG_TRIVIAL(error) << "SnapmakerCloud: no G-code for plate " << params.plate_index << " in " << gcode_path;
            return BAMBU_NETWORK_ERR_FILE_NOT_EXIST;
        }
        gcode_path = extracted.string();
    }
    struct Cleanup
    {
        boost::filesystem::path path;
        ~Cleanup()
        {
            boost::system::error_code ec;
            if (!path.empty())
                boost::filesystem::remove(path, ec);
        }
    } cleanup{extracted};

    if (!boost::filesystem::exists(gcode_path))
        return BAMBU_NETWORK_ERR_FILE_NOT_EXIST;

    SC::Device device;
    if (!find_device(params.dev_id, device)) {
        update(PrintingStageERROR, 0, _u8L("The printer is not on this Snapmaker account."));
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }
    if (!device.online) {
        update(PrintingStageERROR, 0, _u8L("The printer is offline. Turn it on and connect it to the internet."));
        return BAMBU_NETWORK_ERR_INVALID_HANDLE;
    }

    SC::Client   client(session);
    SC::Uploaded uploaded;
    std::string  error;
    update(PrintingStageUpload, 0, _u8L("Uploading to Snapmaker..."));
    int code = client.upload(
        gcode_path, file_name(params, gcode_path), device.id,
        [&](int percent) { update(PrintingStageUpload, percent, _u8L("Uploading to Snapmaker...")); }, [&] { return cancel_fn && cancel_fn(); },
        uploaded, error);
    if (code == SC::CODE_CANCELLED)
        return BAMBU_NETWORK_ERR_CANCELED;
    if (code != SC::CODE_OK) {
        BOOST_LOG_TRIVIAL(error) << "SnapmakerCloud: upload failed (" << code << "): " << error;
        update(PrintingStageERROR, code, code == SC::CODE_UNAUTHORIZED ? _u8L("Snapmaker sign-in expired. Sign in again.") : error);
        return BAMBU_NETWORK_ERR_PRINT_WR_UPLOAD_FTP_FAILED;
    }
    if (cancel_fn && cancel_fn())
        return BAMBU_NETWORK_ERR_CANCELED;

    update(PrintingStageSending, 0, start ? _u8L("Starting print...") : _u8L("Sending to the printer..."));
    json reply;
    code = rpc(params.dev_id, SC::print_request(0, uploaded, device.firmware, start, 0), reply, std::chrono::seconds(30), error);
    if (code != SC::CODE_OK) {
        BOOST_LOG_TRIVIAL(error) << "SnapmakerCloud: starting the print failed (" << code << "): " << error;
        update(PrintingStageERROR, code, error);
        return BAMBU_NETWORK_ERR_PRINT_LP_PUBLISH_MSG_FAILED;
    }
    update(PrintingStageFinished, 100, start ? _u8L("Print started") : _u8L("Sent to the printer"));
    return BAMBU_NETWORK_SUCCESS;
}

int SnapmakerCloudPrinterAgent::start_print(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn)
{
    return cloud_print(params, true, std::move(update_fn), std::move(cancel_fn));
}

int SnapmakerCloudPrinterAgent::start_local_print_with_record(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn)
{
    return cloud_print(params, true, std::move(update_fn), std::move(cancel_fn));
}

int SnapmakerCloudPrinterAgent::start_local_print(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn)
{
    return cloud_print(params, true, std::move(update_fn), std::move(cancel_fn));
}

int SnapmakerCloudPrinterAgent::start_send_gcode_to_sdcard(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn)
{
    // "Send" without printing: the printer downloads the file and keeps it in its storage.
    return cloud_print(params, false, std::move(update_fn), std::move(cancel_fn));
}

int SnapmakerCloudPrinterAgent::start_sdcard_print(PrintParams, OnUpdateStatusFn, WasCancelledFn) { return BAMBU_NETWORK_ERR_INVALID_HANDLE; }

} // namespace Slic3r
