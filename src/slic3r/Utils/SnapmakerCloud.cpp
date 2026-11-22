#include "SnapmakerCloud.hpp"
#include "SecretBox.hpp"
#include "SnapmakerMqtt.hpp"

#include "Http.hpp"
#include "slic3r/GUI/DeviceCore/DevStorage.h"
#include "libslic3r/Utils.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <functional>
#include <initializer_list>
#include <ios>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/fstream.hpp>

#include <openssl/evp.h>

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace Slic3r { namespace SnapmakerCloud {

using nlohmann::json;
namespace fs = boost::filesystem;

namespace {

// What Snapmaker Orca's web client sends with every request (its ApiHeaderManager).
constexpr const char* CLIENT_VERSION = "2.4.1 (1)";
constexpr const char* CLIENT_OS      = "Orca";
constexpr const char* CLIENT_DEVICE  = "Orca-Web";

std::string base64(const unsigned char* data, size_t size)
{
    std::string out(4 * ((size + 2) / 3), '\0');
    const int   written = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(out.data()), data, static_cast<int>(size));
    out.resize(written > 0 ? size_t(written) : 0);
    return out;
}

// The API sends ids sometimes as strings and sometimes as numbers.
std::string json_string(const json& obj, const char* key)
{
    if (!obj.is_object())
        return {};
    auto it = obj.find(key);
    if (it == obj.end() || it->is_null())
        return {};
    if (it->is_string())
        return it->get<std::string>();
    if (it->is_number_integer())
        return std::to_string(it->get<long long>());
    if (it->is_number())
        return std::to_string(it->get<double>());
    if (it->is_boolean())
        return it->get<bool>() ? "1" : "0";
    return {};
}

std::string first_string(const json& obj, std::initializer_list<const char*> keys)
{
    for (const char* key : keys)
        if (std::string v = json_string(obj, key); !v.empty())
            return v;
    return {};
}

int json_int(const json& obj, const char* key, int fallback = 0)
{
    if (!obj.is_object())
        return fallback;
    auto it = obj.find(key);
    if (it == obj.end())
        return fallback;
    if (it->is_number())
        return it->get<int>();
    if (it->is_boolean())
        return it->get<bool>() ? 1 : 0;
    if (it->is_string()) {
        try {
            return std::stoi(it->get<std::string>());
        } catch (...) {}
    }
    return fallback;
}

float number(const json& obj, const char* key, float fallback = 0.f)
{
    if (!obj.is_object())
        return fallback;
    auto it = obj.find(key);
    if (it == obj.end())
        return fallback;
    if (it->is_number())
        return it->get<float>();
    return fallback;
}

std::vector<std::string> string_list(const json& v)
{
    std::vector<std::string> out;
    if (v.is_array())
        for (const json& e : v)
            if (e.is_string())
                out.push_back(e.get<std::string>());
    return out;
}

// --- Session file -----------------------------------------------------------------------------

std::mutex  s_session_mutex;
bool        s_session_loaded = false;
Session     s_session;
std::string s_session_file;

std::string session_file_locked()
{
    if (s_session_file.empty())
        s_session_file = (fs::path(data_dir()) / "snapmaker_cloud.json").string();
    return s_session_file;
}

void load_locked()
{
    if (s_session_loaded)
        return;
    s_session_loaded = true;
    try {
        boost::nowide::ifstream in(session_file_locked(), std::ios::binary);
        if (!in)
            return;
        const std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        const json        j = json::parse(SecretBox::open(data, "snapmaker"), nullptr, false);
        if (!j.is_object())
            return;
        s_session.token    = json_string(j, "token");
        s_session.user_id  = json_string(j, "user_id");
        s_session.nickname = json_string(j, "nickname");
        s_session.account  = json_string(j, "account");
        s_session.avatar   = json_string(j, "avatar");
        s_session.region   = region_from_string(json_string(j, "region"));
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: could not read the saved session: " << e.what();
    }
}

void save_locked()
{
    const json j{{"token", s_session.token},     {"user_id", s_session.user_id}, {"nickname", s_session.nickname},
                 {"account", s_session.account}, {"avatar", s_session.avatar},   {"region", region_to_string(s_session.region)}};
    try {
        const std::string data = SecretBox::seal(j.dump(), "snapmaker");
        const std::string file = session_file_locked();
        {
            boost::nowide::ofstream out(file, std::ios::out | std::ios::binary | std::ios::trunc);
            out.write(data.data(), data.size());
        }
#ifndef _WIN32
        ::chmod(file.c_str(), 0600);
#endif
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: could not save the session: " << e.what();
    }
}

std::string gcode_state(const std::string& state)
{
    if (state == "printing")
        return "RUNNING";
    if (state == "paused")
        return "PAUSE";
    if (state == "complete")
        return "FINISH";
    if (state == "error")
        return "FAILED";
    return "IDLE";
}

int64_t new_request_id()
{
    static std::atomic<int64_t> counter{0};
    const int64_t               ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    return (ms % 1000000000LL) * 100 + (counter++ % 100);
}

} // namespace

// --- Regions ------------------------------------------------------------------------------------

std::string region_to_string(Region region) { return region == Region::China ? "China" : "Global"; }

Region region_from_string(const std::string& region) { return boost::iequals(region, "China") ? Region::China : Region::Global; }

std::string api_base_url(Region region) { return region == Region::China ? "https://api.snapmaker.cn/api" : "https://api.snapmaker.com/api"; }

std::string login_url(Region region) { return region == Region::China ? "https://id.snapmaker.cn?from=orca" : "https://id.snapmaker.com?from=orca"; }

std::string account_info_url(Region region)
{
    return region == Region::China ? "https://api.snapmaker.cn/api/common/accounts/current" :
                                     "https://id.snapmaker.com/api/common/accounts/current";
}

// --- SessionStore -------------------------------------------------------------------------------

Session SessionStore::get()
{
    std::lock_guard<std::mutex> lock(s_session_mutex);
    load_locked();
    return s_session;
}

void SessionStore::set(const Session& session)
{
    std::lock_guard<std::mutex> lock(s_session_mutex);
    load_locked();
    s_session = session;
    save_locked();
}

void SessionStore::clear()
{
    std::lock_guard<std::mutex> lock(s_session_mutex);
    load_locked();
    const Region region = s_session.region;
    s_session           = Session();
    s_session.region    = region;
    save_locked();
}

void SessionStore::set_file(const std::string& path)
{
    std::lock_guard<std::mutex> lock(s_session_mutex);
    s_session_file   = path;
    s_session_loaded = false;
    s_session        = Session();
}

// --- Pure helpers -------------------------------------------------------------------------------

std::string Uploaded::print_url() const { return boost::istarts_with(url, "http") || file_path.empty() ? url : file_path; }

std::string token_from_url(const std::string& url)
{
    // Only a query or fragment parameter named exactly "token".
    for (size_t pos = url.find("token="); pos != std::string::npos; pos = url.find("token=", pos + 1)) {
        if (pos == 0 || (url[pos - 1] != '?' && url[pos - 1] != '&' && url[pos - 1] != '#'))
            continue;
        const size_t start = pos + 6;
        const size_t end   = url.find_first_of("&#", start);
        return url.substr(start, end == std::string::npos ? std::string::npos : end - start);
    }
    return {};
}

std::string token_from_callback_body(const std::string& body)
{
    const json j = json::parse(body, nullptr, false);
    if (!j.is_object() || !j.contains("data") || !j["data"].is_object())
        return {};
    return json_string(j["data"], "access_token");
}

std::optional<Region> sign_in_region(const std::string& url)
{
    const std::string host = Http::https_host(url);
    auto              on   = [&host](const std::string& site) { return host == site || boost::ends_with(host, "." + site); };
    if (on("snapmaker.com"))
        return Region::Global;
    if (on("snapmaker.cn"))
        return Region::China;
    return std::nullopt;
}

std::map<std::string, std::string> headers(const Session& session)
{
    std::map<std::string, std::string> h{
        {"Accept", "application/json"},
        {"Content-Type", "application/json"},
        {"Accept-Language", session.region == Region::China ? "zh-CN,zh;q=0.9" : "en-US,en;q=0.9"},
        {"App-Version", CLIENT_VERSION},
        {"OS", CLIENT_OS},
        {"Device-Type", CLIENT_DEVICE},
        {"X-Custom-Site", std::string("Lava-") + CLIENT_OS},
        {"User-Agent", std::string("Lava/") + CLIENT_VERSION + " (" + CLIENT_OS + " " + CLIENT_DEVICE + ")"},
    };
    if (!session.token.empty())
        h["Authorization"] = session.token;
    return h;
}

int parse_envelope(const std::string& body, json& data, std::string& error)
{
    const json reply = json::parse(body, nullptr, false);
    if (!reply.is_object() || !reply.contains("code")) {
        error = "unexpected reply from the Snapmaker cloud";
        return CODE_PARSE;
    }
    const int code = json_int(reply, "code", CODE_PARSE);
    if (code != 200 && code != 0) {
        error = json_string(reply, "msg");
        if (error.empty())
            error = "Snapmaker cloud error " + std::to_string(code);
        return code == 0 ? CODE_PARSE : code;
    }
    data = reply.contains("data") ? reply["data"] : json();
    return CODE_OK;
}

int parse_account(const std::string& body, Session& session, std::string& error)
{
    json      data;
    const int code = parse_envelope(body, data, error);
    if (code != CODE_OK)
        return code;
    if (!data.is_object()) {
        error = "unexpected account reply from Snapmaker ID";
        return CODE_PARSE;
    }
    session.user_id  = json_string(data, "id");
    session.nickname = json_string(data, "nickname");
    session.account  = json_string(data, "account");
    session.avatar   = json_string(data, "icon");
    return CODE_OK;
}

int parse_devices(const std::string& body, std::vector<Device>& devices, std::string& error)
{
    json      data;
    const int code = parse_envelope(body, data, error);
    if (code != CODE_OK)
        return code;
    // The list itself, or a page object around it.
    if (data.is_object())
        for (const char* key : {"list", "records", "rows"})
            if (data.contains(key) && data[key].is_array()) {
                data = data[key];
                break;
            }
    if (!data.is_array()) {
        error = "unexpected device list from the Snapmaker cloud";
        return CODE_PARSE;
    }
    devices.clear();
    for (const json& item : data) {
        Device d;
        d.id       = first_string(item, {"id", "deviceId"});
        d.sn       = first_string(item, {"sn", "serialNumber"});
        d.name     = first_string(item, {"name", "nickname", "dev_name", "device_name"});
        d.model    = first_string(item, {"productName", "model_name", "machine_type", "productCode"});
        d.firmware = first_string(item, {"version", "pro_version", "firmwareVersion"});
        d.online   = json_int(item, "online") != 0;
        d.status   = json_int(item, "status");
        if (d.sn.empty())
            continue;
        if (d.name.empty())
            d.name = d.model.empty() ? d.sn : d.model;
        devices.push_back(std::move(d));
    }
    return CODE_OK;
}

int parse_mqtt_cert(const std::string& body, MqttCert& cert, std::string& error)
{
    json      data;
    const int code = parse_envelope(body, data, error);
    if (code != CODE_OK)
        return code;
    if (!data.is_object()) {
        error = "unexpected broker settings from the Snapmaker cloud";
        return CODE_PARSE;
    }
    cert           = MqttCert();
    cert.endpoint  = first_string(data, {"endpoint", "ip"});
    cert.client_id = first_string(data, {"clientId", "clientid"});
    cert.cert      = first_string(data, {"cert", "secretId"});
    cert.key       = first_string(data, {"key", "secretKey"});
    cert.ca        = first_string(data, {"ca", "trustCert"});
    cert.port      = json_int(data, "port", 8883);
    // Snapmaker Orca moves the LAN port to the TLS one.
    if (cert.port <= 0 || cert.port == 1884)
        cert.port = 8883;
    if (data.contains("topics") && data["topics"].is_object()) {
        cert.subscribe = string_list(data["topics"].value("subscribe", json::array()));
        cert.publish   = string_list(data["topics"].value("publish", json::array()));
    }
    if (cert.subscribe.empty() && data.contains("subscribeTopics"))
        cert.subscribe = string_list(data["subscribeTopics"]);
    if (cert.publish.empty() && data.contains("publishTopics"))
        cert.publish = string_list(data["publishTopics"]);
    if (!cert.complete()) {
        error = "the Snapmaker cloud returned incomplete broker settings";
        return CODE_PARSE;
    }
    return CODE_OK;
}

std::map<std::string, std::string> topic_map(const std::vector<std::string>& topics)
{
    std::map<std::string, std::string> out;
    for (const std::string& topic : topics) {
        // Split on '/', keyed by the second piece, as Snapmaker Orca does: "/request" -> "request".
        const size_t first = topic.find('/');
        if (first == std::string::npos)
            continue;
        const size_t second = topic.find('/', first + 1);
        out[topic.substr(first + 1, second == std::string::npos ? std::string::npos : second - first - 1)] = topic;
    }
    return out;
}

std::string request_topic(const std::string& sn, const MqttCert& cert)
{
    const auto topics = topic_map(cert.publish);
    const auto it     = topics.find("request");
    return sn + (it != topics.end() ? it->second : std::string("/request"));
}

std::string response_topic(const std::string& sn, const MqttCert& cert)
{
    const auto topics = topic_map(cert.subscribe);
    const auto it     = topics.find("response");
    return sn + (it != topics.end() ? it->second : std::string("/response"));
}

bool firmware_before(const std::string& version, const std::string& reference)
{
    auto parts = [](const std::string& v) {
        std::vector<int> out;
        std::string      digits;
        for (char c : v + ".") {
            if (std::isdigit(static_cast<unsigned char>(c)))
                digits.push_back(c);
            else if (!digits.empty()) {
                out.push_back(std::atoi(digits.c_str()));
                digits.clear();
            }
        }
        return out;
    };
    const std::vector<int> a = parts(version), b = parts(reference);
    if (a.empty())
        return false;
    for (size_t i = 0; i < std::max(a.size(), b.size()); ++i) {
        const int x = i < a.size() ? a[i] : 0, y = i < b.size() ? b[i] : 0;
        if (x != y)
            return x < y;
    }
    return false;
}

json rpc_request(int64_t id, const std::string& method, const json& params)
{
    json r{{"jsonrpc", "2.0"}, {"method", method}, {"id", id}};
    if (!params.is_null())
        r["params"] = params;
    return r;
}

json print_request(int64_t id, const Uploaded& file, const std::string& firmware, bool start, int plate)
{
    json params{{"type", "gcode"}, {"url", file.print_url()}, {"auto_start", start}};
    if (!file.checksum.empty())
        params["checksum"] = file.checksum;
    if (file.size > 0)
        params["size"] = file.size;
    if (plate > 0)
        params["print_plate"] = plate;
    // Firmware before 1.3.0 only knows server.files.pull; a send without printing is a pull too.
    const bool pull = !start || firmware_before(firmware, "1.3.0");
    return rpc_request(id, pull ? "server.files.pull" : "server.files.start_cloud_print", params);
}

json upload_create_body(const std::string& file_name, const std::string& checksum, const std::string& device_id, const std::vector<UploadPart>& parts)
{
    json body{{"fileName", file_name}, {"checkSum", checksum}, {"contentType", "application/octet-stream"}};
    if (!device_id.empty())
        body["deviceId"] = device_id;
    if (!parts.empty()) {
        json list = json::array();
        for (const UploadPart& p : parts)
            list.push_back({{"partNumber", p.number}, {"checkSum", p.checksum}});
        body["uploadParts"] = list;
    }
    return body;
}

int parse_upload_create(const std::string& body, std::string& single_url, std::string& method, json& multipart, std::vector<UploadPart>& parts,
                        std::string& error)
{
    json      data;
    const int code = parse_envelope(body, data, error);
    if (code != CODE_OK)
        return code;
    if (!data.is_object()) {
        error = "unexpected upload reply from the Snapmaker cloud";
        return CODE_PARSE;
    }
    single_url.clear();
    multipart = json();
    if (data.contains("url") && data["url"].is_string()) {
        single_url = data["url"].get<std::string>();
        method     = json_string(data, "method");
        if (method.empty())
            method = "PUT";
        return CODE_OK;
    }
    if (!data.contains("uploadParts") || !data["uploadParts"].is_array()) {
        error = "the Snapmaker cloud returned no upload address";
        return CODE_PARSE;
    }
    for (const json& p : data["uploadParts"]) {
        const int number = json_int(p, "partNumber");
        for (UploadPart& part : parts)
            if (part.number == number)
                part.url = json_string(p, "url");
    }
    for (const UploadPart& part : parts)
        if (part.url.empty()) {
            error = "the Snapmaker cloud returned no address for upload part " + std::to_string(part.number);
            return CODE_PARSE;
        }
    multipart = data;
    return CODE_OK;
}

int parse_upload_completed(const std::string& body, Uploaded& uploaded, std::string& error)
{
    json      data;
    const int code = parse_envelope(body, data, error);
    if (code != CODE_OK)
        return code;
    uploaded.url       = json_string(data, "url");
    uploaded.file_path = json_string(data, "filePath");
    if (uploaded.url.empty() && uploaded.file_path.empty()) {
        error = "the Snapmaker cloud did not return the uploaded file's address";
        return CODE_PARSE;
    }
    return CODE_OK;
}

std::string etag_from_headers(const std::string& headers)
{
    std::string        etag;
    std::istringstream in(headers);
    for (std::string line; std::getline(in, line);) {
        if (!boost::istarts_with(line, "etag:"))
            continue;
        std::string v = line.substr(5);
        v.erase(std::remove_if(v.begin(), v.end(), [](char c) { return c == '"' || c == '\r' || c == '\n'; }), v.end());
        const size_t a = v.find_first_not_of(' '), b = v.find_last_not_of(' ');
        etag           = a == std::string::npos ? std::string() : v.substr(a, b - a + 1);
    }
    return etag;
}

std::string sha256_base64(const std::string& data)
{
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int  length = 0;
    EVP_Digest(data.data(), data.size(), digest, &length, EVP_sha256(), nullptr);
    return base64(digest, length);
}

bool file_checksums(const std::string& path, std::string& whole, std::vector<UploadPart>& parts, uint64_t& size)
{
    boost::nowide::ifstream in(path, std::ios::binary);
    if (!in)
        return false;
    EVP_MD_CTX* all = EVP_MD_CTX_new();
    EVP_DigestInit_ex(all, EVP_sha256(), nullptr);
    std::vector<UploadPart> found;
    std::string             chunk(UPLOAD_PART_SIZE, '\0');
    size = 0;
    while (in) {
        in.read(chunk.data(), std::streamsize(chunk.size()));
        const std::streamsize n = in.gcount();
        if (n <= 0)
            break;
        EVP_DigestUpdate(all, chunk.data(), size_t(n));
        UploadPart part;
        part.number   = int(found.size()) + 1;
        part.checksum = sha256_base64(chunk.substr(0, size_t(n)));
        found.push_back(std::move(part));
        size += uint64_t(n);
    }
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int  length = 0;
    EVP_DigestFinal_ex(all, digest, &length);
    EVP_MD_CTX_free(all);
    whole = base64(digest, length);
    // Snapmaker Orca uploads in one piece up to one part's size.
    parts = size > UPLOAD_PART_SIZE ? std::move(found) : std::vector<UploadPart>();
    return true;
}

const std::string& amazon_root_ca1()
{
    static const std::string pem = "-----BEGIN CERTIFICATE-----\n"
                                   "MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF\n"
                                   "ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6\n"
                                   "b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL\n"
                                   "MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv\n"
                                   "b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj\n"
                                   "ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM\n"
                                   "9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw\n"
                                   "IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6\n"
                                   "VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L\n"
                                   "93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm\n"
                                   "jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC\n"
                                   "AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA\n"
                                   "A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI\n"
                                   "U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs\n"
                                   "N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv\n"
                                   "o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU\n"
                                   "5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy\n"
                                   "rqXRfboQnoZsG4q5WTP468SQvvG5\n"
                                   "-----END CERTIFICATE-----\n";
    return pem;
}

json ssdp_payload(const Device& device)
{
    json payload;
    payload["dev_name"] = device.name;
    payload["dev_id"]   = device.sn;
    // No address: the printer is reached through the cloud. The serial keeps the field non-empty.
    payload["dev_ip"]       = device.sn;
    payload["dev_type"]     = device.model;
    payload["dev_signal"]   = "0";
    payload["connect_type"] = "cloud";
    payload["bind_state"]   = "occupied";
    payload["sec_link"]     = "secure";
    payload["ssdp_version"] = "v1";
    payload["online"]       = device.online;
    payload["status"]       = device.online ? "Online" : "Offline";
    return payload;
}

json status_payload(const Device& device, const json& status)
{
    // `status` is a Moonraker printer.objects.query result: {"status": {"print_stats": {...}, ...}}.
    const json  objects = status.is_object() && status.contains("status") ? status["status"] : status;
    const json  stats   = objects.is_object() ? objects.value("print_stats", json::object()) : json::object();
    const json  display = objects.is_object() ? objects.value("display_status", json::object()) : json::object();
    const json  nozzle  = objects.is_object() ? objects.value("extruder", json::object()) : json::object();
    const json  bed     = objects.is_object() ? objects.value("heater_bed", json::object()) : json::object();
    const std::string state = json_string(stats, "state");

    json print;
    print["command"]             = "push_status";
    print["msg"]                 = 0;
    print["support_mqtt_alive"]  = true;
    print["gcode_state"]         = device.online ? gcode_state(state) : "OFFLINE";
    print["mc_print_stage"]      = state == "printing" ? 1 : state == "paused" ? 2 : 0;
    print["mc_print_error_code"] = 0;
    print["print_error"]         = 0;
    print["mc_percent"]          = int(number(display, "progress") * 100.f + 0.5f);
    const float elapsed          = number(stats, "print_duration");
    const float progress         = number(display, "progress");
    print["mc_remaining_time"]   = progress > 0.01f ? int(elapsed / progress * (1.f - progress) / 60.f) : 0;
    const std::string file       = json_string(stats, "filename");
    print["subtask_name"]        = file;
    print["gcode_file"]          = file;
    // The printer keeps its own storage; report it present so the send dialog does not block on it.
    print["sdcard"]               = true;
    print["home_flag"]            = DevStorage::HAS_SDCARD_NORMAL << 8;
    print["support_send_to_sd"]   = true;
    print["nozzle_temp_range"]    = {0, 300};
    print["bed_temp_range"]       = {0, 110};
    print["nozzle_temper"]        = number(nozzle, "temperature");
    print["nozzle_target_temper"] = number(nozzle, "target");
    print["bed_temper"]           = number(bed, "temperature");
    print["bed_target_temper"]    = number(bed, "target");
    return json{{"print", print}};
}

// --- Printer link -------------------------------------------------------------------------------

struct PrinterLink::Impl
{
    Device                                  device;
    MqttCert                                cert;
    std::unique_ptr<SnapmakerMqtt::Client> mqtt;
};

PrinterLink::PrinterLink(Device device, MqttCert cert) : m(std::make_unique<Impl>())
{
    m->device = std::move(device);
    m->cert   = std::move(cert);
}

PrinterLink::~PrinterLink() = default;

bool PrinterLink::is_open() const { return m->mqtt && m->mqtt->connected(); }

bool PrinterLink::open(std::string& error)
{
    SnapmakerMqtt::TlsConfig cfg;
    cfg.host      = m->cert.endpoint;
    cfg.port      = m->cert.port;
    cfg.client_id = m->cert.client_id;
    cfg.cert_pem  = m->cert.cert;
    cfg.key_pem   = m->cert.key;
    cfg.ca_pem    = m->cert.ca.empty() ? amazon_root_ca1() : m->cert.ca;
    m->mqtt       = std::make_unique<SnapmakerMqtt::Client>(cfg);
    if (!m->mqtt->connect(std::chrono::seconds(20), error) ||
        !m->mqtt->subscribe(response_topic(m->device.sn, m->cert), 1, std::chrono::seconds(10), error)) {
        m->mqtt.reset();
        return false;
    }
    return true;
}

int PrinterLink::request(json request, json& reply, std::chrono::milliseconds timeout, std::string& error)
{
    if (!is_open() && !open(error))
        return CODE_BROKER;
    const int64_t id = new_request_id();
    request["id"]    = id;
    if (!m->mqtt->publish(request_topic(m->device.sn, m->cert), request.dump(), 1, std::chrono::seconds(10), error)) {
        m->mqtt.reset();
        return CODE_BROKER;
    }
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    const std::string topic = response_topic(m->device.sn, m->cert);
    for (;;) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
        if (left.count() <= 0) {
            error = "the printer did not answer";
            return CODE_PRINTER;
        }
        SnapmakerMqtt::Message msg;
        if (!m->mqtt->wait_message(left, msg, error)) {
            if (!m->mqtt->connected())
                m->mqtt.reset();
            if (error.empty() || error.find("timed out") != std::string::npos)
                error = "the printer did not answer";
            return CODE_PRINTER;
        }
        if (msg.topic != topic)
            continue;
        const json r = json::parse(msg.payload, nullptr, false);
        if (!r.is_object() || !r.contains("id") || json_string(r, "id") != std::to_string(id))
            continue; // a status push, or an answer to someone else's request
        if (r.contains("error") && !r["error"].is_null()) {
            const json& e = r["error"];
            error         = e.is_object() ? json_string(e, "message") : e.dump();
            if (error.empty())
                error = "the printer refused the request";
            return CODE_PRINTER;
        }
        error.clear();
        reply = r.value("result", json::object());
        // Snapmaker's file commands answer with a state.
        const std::string state = json_string(reply, "state");
        if (state == "error" || state == "busy") {
            error = json_string(reply, "message");
            if (error.empty())
                error = state == "busy" ? "the printer is busy" : "the printer refused the request";
            return CODE_PRINTER;
        }
        return CODE_OK;
    }
}

// --- Client -------------------------------------------------------------------------------------

Client::Client(Session session) : m_session(std::move(session)) {}

namespace {

int perform(Http& http, std::string& reply, std::string& error)
{
    int code = CODE_NETWORK;
    http.tls_verify(true)
        .timeout_connect(10)
        .timeout_max(30)
        .on_complete([&](std::string body, unsigned) {
            reply = std::move(body);
            code  = CODE_OK;
        })
        .on_error([&](std::string body, std::string err, unsigned status) {
            reply = std::move(body);
            error = err.empty() ? "HTTP " + std::to_string(status) : err;
            code  = status == 401 ? CODE_UNAUTHORIZED : CODE_NETWORK;
        })
        .perform_sync();
    return code;
}

void apply_headers(Http& http, const std::map<std::string, std::string>& h)
{
    for (const auto& [name, value] : h)
        http.header(name, value);
}

// Server code to local code: the envelope's 401 means the sign-in expired.
int result_of(int http_code, const std::string& reply, std::string& error, const std::function<int(const std::string&, std::string&)>& parse)
{
    if (http_code != CODE_OK) {
        if (!reply.empty()) {
            json        ignored;
            std::string server_error;
            const int   server = parse_envelope(reply, ignored, server_error);
            if (server != CODE_OK && server != CODE_PARSE) {
                error = server_error;
                return server;
            }
        }
        return http_code;
    }
    return parse(reply, error);
}

} // namespace

int Client::post_json(const std::string& path, const json& body, std::string& reply, std::string& error) const
{
    Http http = Http::post(api_base_url(m_session.region) + path);
    apply_headers(http, headers(m_session));
    http.set_post_body(body.dump());
    return perform(http, reply, error);
}

int Client::get(const std::string& path, std::string& reply, std::string& error) const
{
    Http http = Http::get(api_base_url(m_session.region) + path);
    apply_headers(http, headers(m_session));
    return perform(http, reply, error);
}

int Client::sign_in_with_token(Region region, const std::string& token, Session& out, std::string& error)
{
    if (token.empty()) {
        error = "no token";
        return CODE_NO_LOGIN;
    }
    out        = Session();
    out.region = region;
    out.token  = token;
    Http http  = Http::get(account_info_url(region));
    apply_headers(http, headers(out));
    std::string reply;
    const int   code = perform(http, reply, error);
    return result_of(code, reply, error, [&out](const std::string& r, std::string& e) { return parse_account(r, out, e); });
}

int Client::list_devices(std::vector<Device>& devices, std::string& error)
{
    if (!m_session.valid())
        return CODE_NO_LOGIN;
    // The same body Snapmaker Orca posts: every filter empty.
    const json body{{"name", nullptr},        {"mac", nullptr},       {"sn", nullptr},      {"productName", nullptr},
                    {"productCode", nullptr}, {"pageIndex", nullptr}, {"pageRows", nullptr}};
    std::string reply;
    const int   code = post_json("/user/device/list", body, reply, error);
    return result_of(code, reply, error, [&devices](const std::string& r, std::string& e) { return parse_devices(r, devices, e); });
}

int Client::mqtt_cert(MqttCert& cert, std::string& error)
{
    if (!m_session.valid())
        return CODE_NO_LOGIN;
    std::string reply;
    const int   code = get("/user/device/getMqttCert", reply, error);
    return result_of(code, reply, error, [&cert](const std::string& r, std::string& e) { return parse_mqtt_cert(r, cert, e); });
}

int Client::put_file(const std::string& url, const std::string& method, const std::string& path, const std::string& checksum,
                     const ProgressFn& progress, const CancelledFn& cancelled, std::string* etag, std::string& error) const
{
    // The create reply names PUT; the storage takes nothing else for a presigned upload.
    if (!boost::iequals(method, "PUT"))
        BOOST_LOG_TRIVIAL(warning) << "SnapmakerCloud: upload method " << method << " requested, using PUT";
    Http http = Http::put(url);
    // Presigned storage URL: only the headers it was signed with, no account token.
    http.header("Content-Type", "application/octet-stream").header("x-amz-checksum-sha256", checksum).header("Expect", "");
    http.set_put_body(fs::path(path));
    int         code       = CODE_NETWORK;
    bool        was_cancel = false;
    std::string received_headers;
    http.tls_verify(true)
        .timeout_connect(10)
        .on_header_callback([&](std::string h) { received_headers = std::move(h); })
        .on_progress([&](Http::Progress p, bool& cancel) {
            if (cancelled && cancelled()) {
                cancel     = true;
                was_cancel = true;
                return;
            }
            if (progress && p.ultotal > 0)
                progress(int(p.ulnow * 100 / p.ultotal));
        })
        .on_complete([&](std::string, unsigned) { code = CODE_OK; })
        .on_error([&](std::string body, std::string err, unsigned status) {
            error = err.empty() ? "upload rejected (HTTP " + std::to_string(status) + ")" : err;
            BOOST_LOG_TRIVIAL(error) << "SnapmakerCloud: storage upload failed: " << error << " " << body.substr(0, 400);
        })
        .perform_sync();
    if (etag)
        *etag = etag_from_headers(received_headers);
    return was_cancel ? CODE_CANCELLED : code;
}

int Client::upload(const std::string& local_path, const std::string& file_name, const std::string& device_id, const ProgressFn& progress,
                   const CancelledFn& cancelled, Uploaded& uploaded, std::string& error)
{
    if (!m_session.valid())
        return CODE_NO_LOGIN;
    std::vector<UploadPart> parts;
    uploaded = Uploaded();
    if (!file_checksums(local_path, uploaded.checksum, parts, uploaded.size)) {
        error = "could not read " + local_path;
        return CODE_FILE;
    }
    const json  create = upload_create_body(file_name, uploaded.checksum, device_id, parts);
    std::string reply, single_url, method;
    json        multipart;
    int         code = post_json("/user/device/upload/create", create, reply, error);
    code = result_of(code, reply, error, [&](const std::string& r, std::string& e) { return parse_upload_create(r, single_url, method, multipart, parts, e); });
    if (code != CODE_OK)
        return code;

    json completed_body;
    if (!single_url.empty()) {
        code = put_file(single_url, method, local_path, uploaded.checksum, progress, cancelled, nullptr, error);
        if (code != CODE_OK)
            return code;
        completed_body = create;
    } else {
        // One PUT per part, each from a temporary file holding that slice.
        boost::nowide::ifstream in(local_path, std::ios::binary);
        std::string             chunk(UPLOAD_PART_SIZE, '\0');
        boost::system::error_code ec;
        const fs::path            tmp = fs::temp_directory_path(ec) / fs::unique_path("snapmaker-part-%%%%-%%%%.bin", ec);
        for (UploadPart& part : parts) {
            in.seekg(std::streamoff(part.number - 1) * std::streamoff(UPLOAD_PART_SIZE));
            in.read(chunk.data(), std::streamsize(chunk.size()));
            const std::streamsize n = in.gcount();
            if (n <= 0) {
                error = "could not read " + local_path;
                return CODE_FILE;
            }
            {
                boost::nowide::ofstream out(tmp.string(), std::ios::binary | std::ios::trunc);
                out.write(chunk.data(), n);
            }
            const int  index = part.number - 1;
            const int  count = int(parts.size());
            ProgressFn part_progress = [&](int pct) {
                if (progress)
                    progress((index * 100 + pct) / count);
            };
            code = put_file(part.url, "PUT", tmp.string(), part.checksum, part_progress, cancelled, &part.etag, error);
            if (code == CODE_OK && part.etag.empty()) {
                error = "the storage did not confirm upload part " + std::to_string(part.number);
                code  = CODE_NETWORK;
            }
            if (code != CODE_OK) {
                fs::remove(tmp, ec);
                std::string ignored, ignored_reply;
                post_json("/user/device/upload/cancel", json{{"uploadId", json_string(multipart, "uploadId")}}, ignored_reply, ignored);
                return code;
            }
        }
        fs::remove(tmp, ec);
        // The create reply with the file's details and each part's ETag, as Snapmaker Orca completes it.
        completed_body = multipart;
        completed_body.erase("method");
        completed_body.erase("contentType");
        completed_body["checkSum"] = uploaded.checksum;
        completed_body["fileName"] = file_name;
        if (!device_id.empty())
            completed_body["deviceId"] = device_id;
        for (json& p : completed_body["uploadParts"])
            for (const UploadPart& part : parts)
                if (json_int(p, "partNumber") == part.number)
                    p["etag"] = part.etag;
    }
    code = post_json("/user/device/upload/completed", completed_body, reply, error);
    return result_of(code, reply, error, [&uploaded](const std::string& r, std::string& e) { return parse_upload_completed(r, uploaded, e); });
}

int Client::rpc(const Device& device, const std::string& method, const json& params, json& result, std::string& error)
{
    MqttCert  cert;
    const int code = mqtt_cert(cert, error);
    if (code != CODE_OK)
        return code;
    PrinterLink link(device, cert);
    return link.request(rpc_request(0, method, params), result, std::chrono::seconds(20), error);
}

int Client::start_print(const Device& device, const Uploaded& file, bool start, int plate, std::string& error)
{
    MqttCert  cert;
    const int code = mqtt_cert(cert, error);
    if (code != CODE_OK)
        return code;
    PrinterLink link(device, cert);
    json        result;
    return link.request(print_request(0, file, device.firmware, start, plate), result, std::chrono::seconds(30), error);
}

}} // namespace Slic3r::SnapmakerCloud
