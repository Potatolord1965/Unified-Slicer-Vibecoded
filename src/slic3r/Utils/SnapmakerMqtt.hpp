#pragma once

// A small MQTT 3.1.1 client over TLS with a client certificate, enough for the Snapmaker cloud:
// connect, subscribe, publish and wait for one reply. It blocks the calling thread, so it runs on a
// worker thread, and every call has a deadline. No third-party MQTT library is needed: the slicer
// already links Boost.Asio and OpenSSL.
//
// Snapmaker's cloud broker is AWS IoT Core. It authenticates the client by the certificate and key
// the Snapmaker API hands out (/user/device/getMqttCert); the broker's own certificate chains to
// Amazon Root CA 1.

#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace Slic3r { namespace SnapmakerMqtt {

struct TlsConfig
{
    std::string host;
    int         port = 8883;
    std::string client_id;
    std::string ca_pem;   // Trusted root(s); empty uses the system store
    std::string cert_pem; // Client certificate
    std::string key_pem;  // Client private key
    std::string username;
    std::string password;
    int         keep_alive_s = 60;
    bool        verify_peer  = true;
};

struct Message
{
    std::string topic;
    std::string payload;
};

// --- Packet encoding (pure, unit tested) -----------------------------------------------------------

std::string encode_remaining_length(size_t length);
// Decodes a remaining-length field at data[pos]. Returns the number of bytes it takes, 0 when more
// data is needed, -1 when malformed.
int         decode_remaining_length(const std::string& data, size_t pos, size_t& length);
std::string encode_connect(const std::string& client_id, int keep_alive_s, const std::string& username, const std::string& password);
std::string encode_subscribe(uint16_t packet_id, const std::string& topic, int qos);
std::string encode_publish(const std::string& topic, const std::string& payload, int qos, uint16_t packet_id);
std::string encode_puback(uint16_t packet_id);

// One complete control packet taken off a byte stream.
struct Packet
{
    uint8_t     type  = 0; // high nibble of the first byte
    uint8_t     flags = 0; // low nibble
    std::string body;      // variable header and payload
};
// Takes the first complete packet off `buffer`. Returns 1 when one was taken, 0 when more data is
// needed, -1 when the stream is malformed.
int take_packet(std::string& buffer, Packet& packet);

class Client
{
public:
    explicit Client(TlsConfig config);
    ~Client();
    Client(const Client&)            = delete;
    Client& operator=(const Client&) = delete;

    // TCP + TLS handshake + CONNECT/CONNACK.
    bool connect(std::chrono::milliseconds timeout, std::string& error);
    // SUBSCRIBE and wait for its SUBACK.
    bool subscribe(const std::string& topic, int qos, std::chrono::milliseconds timeout, std::string& error);
    // PUBLISH; with qos 1 waits for the PUBACK.
    bool publish(const std::string& topic, const std::string& payload, int qos, std::chrono::milliseconds timeout, std::string& error);
    // Waits for the next PUBLISH the broker sends on a subscribed topic.
    bool wait_message(std::chrono::milliseconds timeout, Message& message, std::string& error);
    // Sends DISCONNECT and closes the connection. Also done by the destructor.
    void disconnect();

    bool connected() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

}} // namespace Slic3r::SnapmakerMqtt
