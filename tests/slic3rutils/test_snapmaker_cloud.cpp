#include <catch2/catch_test_macros.hpp>

#include <string>
#include <cstddef>
#include <cstdint>
#include <ios>
#include <vector>

#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/nowide/fstream.hpp>
#include <nlohmann/json.hpp>

#include "slic3r/Utils/SnapmakerCloud.hpp"
#include "slic3r/Utils/SnapmakerMqtt.hpp"

namespace SC = Slic3r::SnapmakerCloud;
namespace SM = Slic3r::SnapmakerMqtt;
using nlohmann::json;

TEST_CASE("Snapmaker ID token is read from the sign-in redirect", "[SnapmakerCloud]")
{
    CHECK(SC::token_from_url("https://id.snapmaker.com/?token=abc.def&x=1") == "abc.def");
    CHECK(SC::token_from_url("https://x/#token=zz") == "zz");
    CHECK(SC::token_from_url("https://id.snapmaker.com/?mytoken=abc").empty());
    CHECK(SC::token_from_callback_body(R"({"code":200,"data":{"access_token":"T1"}})") == "T1");
    CHECK(SC::token_from_callback_body("not json").empty());
}

TEST_CASE("Snapmaker sign-in tokens are taken only from Snapmaker pages", "[SnapmakerCloud]")
{
    CHECK(SC::sign_in_region("https://id.snapmaker.com/?token=t") == SC::Region::Global);
    CHECK(SC::sign_in_region("https://SNAPMAKER.com/") == SC::Region::Global);
    CHECK(SC::sign_in_region("https://api.snapmaker.cn/api/oauth2/callback/x") == SC::Region::China);
    CHECK_FALSE(SC::sign_in_region("https://evil.example/?next=snapmaker.cn&token=t").has_value());
    CHECK_FALSE(SC::sign_in_region("https://notsnapmaker.com/?token=t").has_value());
    CHECK_FALSE(SC::sign_in_region("https://id.snapmaker.com.evil.example/?token=t").has_value());
    CHECK_FALSE(SC::sign_in_region("https://id.snapmaker.com@evil.example/?token=t").has_value());
    CHECK_FALSE(SC::sign_in_region("http://id.snapmaker.com/?token=t").has_value());
}

TEST_CASE("Snapmaker API envelope and device list", "[SnapmakerCloud]")
{
    json        data;
    std::string error;
    CHECK(SC::parse_envelope(R"({"code":200,"msg":"ok","data":[1]})", data, error) == SC::CODE_OK);
    CHECK(data.is_array());
    CHECK(SC::parse_envelope(R"({"code":401,"msg":"expired"})", data, error) == 401);
    CHECK(error == "expired");

    std::vector<SC::Device> devices;
    REQUIRE(SC::parse_devices(R"({"code":200,"data":[{"id":12,"sn":"SN1","name":"U1 A","productName":"Snapmaker U1","online":1,"version":"1.3.2"},{"id":13,"sn":""}]})",
                              devices, error) == SC::CODE_OK);
    REQUIRE(devices.size() == 1); // a device without a serial number cannot be reached
    CHECK(devices[0].id == "12");
    CHECK(devices[0].online);
    CHECK(devices[0].firmware == "1.3.2");
}

TEST_CASE("Snapmaker broker settings and topics", "[SnapmakerCloud]")
{
    SC::MqttCert cert;
    std::string  error;
    REQUIRE(SC::parse_mqtt_cert(R"({"code":200,"data":{"endpoint":"a.iot.aws","port":1884,"clientId":"cid","cert":"C","key":"K","topics":{"publish":["/request","/config/request"],"subscribe":["/response","/status"]}}})",
                                cert, error) == SC::CODE_OK);
    CHECK(cert.port == 8883); // the API reports the WebSocket port; TLS is on 8883
    CHECK(cert.complete());
    CHECK(SC::request_topic("SN1", cert) == "SN1/request");
    CHECK(SC::response_topic("SN1", cert) == "SN1/response");
    CHECK(SC::topic_map({"/config/request"}).count("config") == 1);
}

TEST_CASE("Snapmaker print command depends on the firmware", "[SnapmakerCloud]")
{
    CHECK(SC::firmware_before("1.2.9", "1.3.0"));
    CHECK_FALSE(SC::firmware_before("1.3.0", "1.3.0"));
    CHECK_FALSE(SC::firmware_before("", "1.3.0"));
    CHECK_FALSE(SC::firmware_before("v1.10.0", "1.3.0"));

    SC::Uploaded file;
    file.url      = "https://s3/x.gcode";
    file.checksum = "ck";
    file.size     = 10;
    const json r  = SC::print_request(5, file, "1.3.1", true, 0);
    CHECK(r["method"] == "server.files.start_cloud_print");
    CHECK(r["params"]["auto_start"] == true);
    CHECK(r["params"]["url"] == "https://s3/x.gcode");
    CHECK_FALSE(r["params"].contains("print_plate"));
    CHECK(SC::print_request(5, file, "1.2.0", true, 1)["method"] == "server.files.pull");
    CHECK(SC::print_request(5, file, "1.3.1", false, 0)["method"] == "server.files.pull");
}

TEST_CASE("Snapmaker upload checksums and replies", "[SnapmakerCloud]")
{
    CHECK(SC::sha256_base64("abc") == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
    CHECK(SC::etag_from_headers("HTTP/1.1 200 OK\r\nETag: \"abc123\"\r\n\r\n") == "abc123");

    const auto dir = boost::filesystem::temp_directory_path() / boost::filesystem::unique_path("snapmaker-%%%%%%");
    boost::filesystem::create_directories(dir);
    const std::string big = (dir / "big.gcode").string(), small = (dir / "small.gcode").string();
    {
        boost::nowide::ofstream f(big, std::ios::binary);
        f << std::string(SC::UPLOAD_PART_SIZE * 2 + 100, 'a');
        boost::nowide::ofstream g(small, std::ios::binary);
        g << "abc";
    }
    std::string                 whole;
    std::vector<SC::UploadPart> parts;
    uint64_t                    size = 0;
    REQUIRE(SC::file_checksums(big, whole, parts, size));
    CHECK(parts.size() == 3);
    CHECK(parts[2].number == 3);
    CHECK(size == SC::UPLOAD_PART_SIZE * 2 + 100);
    REQUIRE(SC::file_checksums(small, whole, parts, size));
    CHECK(parts.empty());
    CHECK(whole == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
    boost::filesystem::remove_all(dir);

    std::string single, method, error;
    json        multipart;
    parts = {{1, "a"}, {2, "b"}};
    REQUIRE(SC::parse_upload_create(R"({"code":200,"data":{"uploadId":"U","uploadParts":[{"partNumber":1,"url":"https://p1"},{"partNumber":2,"url":"https://p2"}]}})",
                                    single, method, multipart, parts, error) == SC::CODE_OK);
    CHECK(single.empty());
    CHECK(parts[1].url == "https://p2");
    REQUIRE(SC::parse_upload_create(R"({"code":200,"data":{"url":"https://one","method":"PUT"}})", single, method, multipart, parts, error) ==
            SC::CODE_OK);
    CHECK(single == "https://one");

    SC::Uploaded uploaded;
    REQUIRE(SC::parse_upload_completed(R"({"code":200,"data":{"url":"https://dl/x.gcode"}})", uploaded, error) == SC::CODE_OK);
    CHECK(uploaded.print_url() == "https://dl/x.gcode");
}

TEST_CASE("Snapmaker printer status maps to the device panel", "[SnapmakerCloud]")
{
    SC::Device device;
    device.online = true;
    device.sn     = "SN1";
    const json status = SC::status_payload(device, json::parse(R"({"status":{"print_stats":{"state":"printing","filename":"a.gcode","print_duration":600},"display_status":{"progress":0.5},"extruder":{"temperature":210,"target":215}}})"));
    CHECK(status["print"]["gcode_state"] == "RUNNING");
    CHECK(status["print"]["mc_percent"] == 50);
    CHECK(status["print"]["mc_remaining_time"] == 10);

    // A field of an unexpected type reads as missing instead of throwing.
    const json odd = SC::status_payload(device, json::parse(R"({"status":{"print_stats":{"state":["printing"],"filename":7}}})"));
    CHECK(odd["print"]["gcode_state"] == "IDLE");
    CHECK(odd["print"]["subtask_name"] == "7");
}

TEST_CASE("MQTT packets encode and decode", "[SnapmakerMqtt]")
{
    CHECK(SM::encode_remaining_length(0) == std::string(1, '\0'));
    CHECK(SM::encode_remaining_length(127) == std::string(1, '\x7f'));
    CHECK(SM::encode_remaining_length(128) == std::string("\x80\x01", 2));
    size_t length = 0;
    CHECK(SM::decode_remaining_length(std::string("\x80\x01", 2), 0, length) == 2);
    CHECK(length == 128);
    CHECK(SM::decode_remaining_length(std::string("\x80", 1), 0, length) == 0);

    std::string buffer = SM::encode_publish("SN1/request", "{\"id\":1}", 1, 7);
    buffer += SM::encode_puback(7);
    SM::Packet p;
    REQUIRE(SM::take_packet(buffer, p) == 1);
    CHECK(p.type == 3); // PUBLISH
    CHECK(p.body.find("SN1/request") != std::string::npos);
    REQUIRE(SM::take_packet(buffer, p) == 1);
    CHECK(p.type == 4); // PUBACK
    CHECK(buffer.empty());
    CHECK(SM::take_packet(buffer, p) == 0);

    const std::string connect = SM::encode_connect("cid", 60, "", "");
    CHECK(static_cast<unsigned char>(connect[0]) == 0x10);
    CHECK(connect.find("MQTT") != std::string::npos);
}
