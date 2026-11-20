#pragma once

#include "SnapmakerCloud.hpp"
#include "IPrinterAgent.hpp"
#include "bambu_networking.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

namespace Slic3r {

class ICloudServiceAgent;

// Prints to Snapmaker printers (U1) bound to the user's Snapmaker account, from anywhere, the way
// Snapmaker Orca does through Snapmaker's cloud.
//
// Discovery lists every printer on the account (one ssdp message each, refreshed while discovery runs),
// so the Device tab shows them all. Connecting opens a broker link to the chosen printer and polls its
// Moonraker status (printer.objects.query), translated into the Bambu-shaped push_status the device
// panels read. A print is uploaded to Snapmaker's storage and started with
// server.files.start_cloud_print; the printer then downloads it itself, so it works off the local
// network. LAN printing to the same printers stays with SnapmakerPrinterAgent ("snapmaker").
class SnapmakerCloudPrinterAgent : public IPrinterAgent
{
public:
    static constexpr const char* AGENT_ID = "snapmaker_cloud";

    explicit SnapmakerCloudPrinterAgent(std::string log_dir);
    ~SnapmakerCloudPrinterAgent() override;

    static AgentInfo get_agent_info_static();
    AgentInfo        get_agent_info() override { return get_agent_info_static(); }

    void set_cloud_agent(std::shared_ptr<ICloudServiceAgent> cloud) override;

    int send_message(std::string dev_id, std::string json_str, int qos, int flag) override;
    int connect_printer(const PrinterConnectionParams& params) override;
    int disconnect_printer() override;
    int send_message_to_printer(std::string dev_id, std::string json_str, int qos, int flag) override;

    bool start_discovery(bool start, bool sending) override;
    int  bind_detect(std::string, std::string, detectResult&) override { return BAMBU_NETWORK_ERR_INVALID_HANDLE; }
    int  set_server_callback(OnServerErrFn fn) override;

    std::string get_user_selected_machine() override;
    int         set_user_selected_machine(std::string dev_id) override;

    int start_print(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn wait_fn) override;
    int start_local_print_with_record(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn wait_fn) override;
    int start_send_gcode_to_sdcard(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn, OnWaitFn wait_fn) override;
    int start_local_print(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn) override;
    int start_sdcard_print(PrintParams params, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn) override;

    int set_on_ssdp_msg_fn(OnMsgArrivedFn fn) override;
    int set_on_printer_connected_fn(OnPrinterConnectedFn fn) override;
    int set_on_subscribe_failure_fn(GetSubscribeFailureFn fn) override;
    int set_on_message_fn(OnMessageFn fn) override;
    int set_on_user_message_fn(OnMessageFn fn) override;
    int set_on_local_connect_fn(OnLocalConnectedFn fn) override;
    int set_on_local_message_fn(OnMessageFn fn) override;
    int set_queue_on_main_fn(QueueOnMainFn fn) override;

private:
    int  cloud_print(const PrintParams& params, bool start, OnUpdateStatusFn update_fn, WasCancelledFn cancel_fn);
    bool find_device(const std::string& sn, SnapmakerCloud::Device& device);
    // Sends one Moonraker request to the printer over the shared broker link.
    int  rpc(const std::string& dev_id, const nlohmann::json& request, nlohmann::json& reply, std::chrono::milliseconds timeout,
             std::string& error);
    int  control(const std::string& dev_id, const std::string& method, const nlohmann::json& params = nlohmann::json());

    void discovery_loop();
    void status_loop(std::string dev_id, uint64_t generation);
    void stop_discovery();
    // Ends the status loop. The UI thread does not wait for a loop that is inside a network call:
    // it is retired and joined in the destructor (wait = true).
    void stop_status(bool wait = false);

    void post(std::function<void()> fn);
    void dispatch_message(const std::string& dev_id, const std::string& payload);

    std::string m_log_dir;

    mutable std::recursive_mutex        m_mutex;
    std::shared_ptr<ICloudServiceAgent> m_cloud_agent;
    std::string                         m_selected;
    std::map<std::string, SnapmakerCloud::Device> m_devices; // Last device list, by serial

    // One broker link at a time: the broker allows one connection per client id, so status polls,
    // commands and print starts share it.
    std::mutex                                   m_link_mutex;
    std::string                                  m_link_sn;
    std::unique_ptr<SnapmakerCloud::PrinterLink> m_link;

    OnMsgArrivedFn        m_on_ssdp;
    OnPrinterConnectedFn  m_on_printer_connected;
    GetSubscribeFailureFn m_on_subscribe_failure;
    OnMessageFn           m_on_message;
    OnMessageFn           m_on_user_message;
    OnLocalConnectedFn    m_on_local_connect;
    OnMessageFn           m_on_local_message;
    QueueOnMainFn         m_queue_on_main;
    OnServerErrFn         m_on_server_err;

    std::atomic<bool> m_discovery_stop{true};
    std::thread       m_discovery_thread;

    std::atomic<uint64_t> m_status_generation{0};
    std::thread           m_status_thread;
    std::vector<std::thread> m_retired_status_threads;
};

} // namespace Slic3r
