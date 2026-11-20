#pragma once

// Client for the Snapmaker cloud (api.snapmaker.com), the service Snapmaker Orca uses to send a print
// to a Snapmaker U1 bound to the user's account. This is a client of Snapmaker's real service: it
// signs in with the user's Snapmaker ID, uploads the G-code to Snapmaker's storage and sends the
// printer the same print command Snapmaker Orca sends, so Snapmaker's servers deliver the job.
//
// A cloud print is three steps:
//   1. Upload: POST /user/device/upload/create with the file's SHA-256 returns a presigned PUT URL
//      (or one URL per 5 MiB part for larger files); after the PUTs, /user/device/upload/completed
//      returns the file's download URL.
//   2. Broker: /user/device/getMqttCert returns an AWS IoT endpoint, client id, certificate and key,
//      and the account's topic names.
//   3. Start: a Moonraker JSON-RPC request, server.files.start_cloud_print {type, url, auto_start,
//      checksum, size} (server.files.pull on firmware before 1.3.0), published on "<sn>/request";
//      the printer answers on "<sn>/response" and downloads the file itself.
//
// The pure helpers carry no network state so they can be unit tested; Client wraps them with the
// HTTP and MQTT calls.

#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace Slic3r { namespace SnapmakerCloud {

enum class Region { Global, China };

std::string region_to_string(Region region);
Region      region_from_string(const std::string& region);
// REST API root, e.g. https://api.snapmaker.com/api
std::string api_base_url(Region region);
// Snapmaker ID sign-in page, as Snapmaker Orca opens it.
std::string login_url(Region region);
// The signed-in account's profile.
std::string account_info_url(Region region);

// Codes: 0 is success. Server codes are passed through; local failures are negative.
constexpr int CODE_OK           = 0;
constexpr int CODE_UNAUTHORIZED = 401;
constexpr int CODE_NETWORK      = -1;
constexpr int CODE_PARSE        = -2;
constexpr int CODE_CANCELLED    = -3;
constexpr int CODE_NO_LOGIN     = -4;
constexpr int CODE_FILE         = -5;
constexpr int CODE_BROKER       = -6;
constexpr int CODE_PRINTER      = -7;

// Size of one part of a multipart upload, as Snapmaker Orca splits files.
constexpr size_t UPLOAD_PART_SIZE = 5242880;

struct Session
{
    std::string token;   // Snapmaker ID access token, sent as the Authorization header
    std::string user_id;
    std::string nickname;
    std::string account; // e-mail
    std::string avatar;
    Region      region = Region::Global;

    bool valid() const { return !token.empty(); }
};

// The signed-in account, shared by the account agent, the printer agent and the send dialog, and
// kept encrypted in <data_dir>/snapmaker_cloud.json between runs.
class SessionStore
{
public:
    static Session get();
    static void    set(const Session& session);
    static void    clear();
    // Defaults to <data_dir>/snapmaker_cloud.json; tests point it elsewhere.
    static void    set_file(const std::string& path);
};

struct Device
{
    std::string id;       // account device id (deviceId in the upload calls)
    std::string sn;       // serial number: the MQTT topic prefix
    std::string name;
    std::string model;    // productName, e.g. "Snapmaker U1"
    std::string firmware; // version as reported to the cloud
    bool        online = false;
    int         status = 0;
};

struct MqttCert
{
    std::string              endpoint;
    int                      port = 8883;
    std::string              client_id;
    std::string              cert;
    std::string              key;
    std::string              ca;
    std::vector<std::string> publish;   // topic templates, e.g. "/request"
    std::vector<std::string> subscribe; // e.g. "/response"

    bool complete() const { return !endpoint.empty() && port > 0 && !client_id.empty() && !cert.empty() && !key.empty(); }
};

struct UploadPart
{
    int         number = 0; // 1-based
    std::string checksum;   // base64 SHA-256 of the part
    std::string url;        // presigned PUT URL, from the create reply
    std::string etag;       // from the PUT reply
};

struct Uploaded
{
    std::string url;       // download URL handed to the printer
    std::string file_path; // storage path, when the server returns one instead
    std::string checksum;  // base64 SHA-256 of the whole file
    uint64_t    size = 0;

    std::string print_url() const;
};

// --- Pure helpers ---------------------------------------------------------------------------------

// The token Snapmaker ID hands back in the URL it redirects to after sign-in ("...token=<t>&...").
std::string token_from_url(const std::string& url);
// The token in the body of the OAuth callback page ({"data":{"access_token":...}}).
std::string token_from_callback_body(const std::string& body);

std::map<std::string, std::string> headers(const Session& session);

// Unwraps the {"code","msg","data"} envelope; code 200 or 0 is success.
int parse_envelope(const std::string& body, nlohmann::json& data, std::string& error);
int parse_account(const std::string& body, Session& session, std::string& error);
int parse_devices(const std::string& body, std::vector<Device>& devices, std::string& error);
int parse_mqtt_cert(const std::string& body, MqttCert& cert, std::string& error);

// Topic templates keyed by their first path segment ("/request" -> "request").
std::map<std::string, std::string> topic_map(const std::vector<std::string>& topics);
std::string                        request_topic(const std::string& sn, const MqttCert& cert);
std::string                        response_topic(const std::string& sn, const MqttCert& cert);

// True when `version` is older than `reference` (dotted numbers; empty counts as current).
bool firmware_before(const std::string& version, const std::string& reference);
// The JSON-RPC request that starts a print of an uploaded file.
nlohmann::json print_request(int64_t id, const Uploaded& file, const std::string& firmware, bool start, int plate);
// Moonraker JSON-RPC control request (printer.print.pause, ...).
nlohmann::json rpc_request(int64_t id, const std::string& method, const nlohmann::json& params = nlohmann::json());

nlohmann::json upload_create_body(const std::string& file_name, const std::string& checksum, const std::string& device_id,
                                  const std::vector<UploadPart>& parts);
// Reads the create reply: a single URL, or the per-part URLs (merged into `parts` by part number).
int  parse_upload_create(const std::string& body, std::string& single_url, std::string& method, nlohmann::json& multipart,
                         std::vector<UploadPart>& parts, std::string& error);
int  parse_upload_completed(const std::string& body, Uploaded& uploaded, std::string& error);
// The ETag of an HTTP reply, without quotes.
std::string etag_from_headers(const std::string& headers);

std::string sha256_base64(const std::string& data);
// SHA-256 of the whole file plus one per UPLOAD_PART_SIZE part (only when the file is larger than one part).
bool        file_checksums(const std::string& path, std::string& whole, std::vector<UploadPart>& parts, uint64_t& size);

// Amazon Root CA 1, the root of the AWS IoT broker's certificate.
const std::string& amazon_root_ca1();

// The ssdp message announcing a printer to the device panels.
nlohmann::json ssdp_payload(const Device& device);
// The Bambu-shaped push_status the device panels read.
nlohmann::json status_payload(const Device& device, const nlohmann::json& print_stats);

// --- Printer link -----------------------------------------------------------------------------------

// One broker connection to one printer: Moonraker JSON-RPC requests on "<sn>/request", answers on
// "<sn>/response", matched by id. Blocking; use it from a worker thread.
class PrinterLink
{
public:
    PrinterLink(Device device, MqttCert cert);
    ~PrinterLink();

    bool open(std::string& error);
    bool is_open() const;
    // Sends `request` (its "id" is set here) and waits for the reply with the same id.
    int  request(nlohmann::json request, nlohmann::json& reply, std::chrono::milliseconds timeout, std::string& error);

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

// --- Client -----------------------------------------------------------------------------------------

using ProgressFn  = std::function<void(int percent)>;
using CancelledFn = std::function<bool()>;

class Client
{
public:
    explicit Client(Session session);

    // Validates a token from the sign-in page and fills in the account.
    static int sign_in_with_token(Region region, const std::string& token, Session& out, std::string& error);

    int list_devices(std::vector<Device>& devices, std::string& error);
    int mqtt_cert(MqttCert& cert, std::string& error);
    int upload(const std::string& local_path, const std::string& file_name, const std::string& device_id, const ProgressFn& progress,
               const CancelledFn& cancelled, Uploaded& uploaded, std::string& error);
    // Starts (or with start = false only downloads) an uploaded file on the printer and waits for its answer.
    int start_print(const Device& device, const Uploaded& file, bool start, int plate, std::string& error);
    // Sends one Moonraker request to the printer through the broker and returns its result.
    int rpc(const Device& device, const std::string& method, const nlohmann::json& params, nlohmann::json& result, std::string& error);

private:
    int post_json(const std::string& path, const nlohmann::json& body, std::string& reply, std::string& error) const;
    int get(const std::string& path, std::string& reply, std::string& error) const;
    int put_file(const std::string& url, const std::string& method, const std::string& path, const std::string& checksum,
                 const ProgressFn& progress, const CancelledFn& cancelled, std::string* etag, std::string& error) const;

    Session m_session;
};

}} // namespace Slic3r::SnapmakerCloud
