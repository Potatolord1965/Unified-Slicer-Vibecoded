#include "SnapmakerMqtt.hpp"

#include <algorithm>
#include <array>
#include <functional>
#include <set>
#include <utility>

#include <boost/asio/buffer.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>
#include <boost/asio/ssl/host_name_verification.hpp>
#include <boost/asio/ssl/stream.hpp>
#include <boost/asio/write.hpp>
#include <boost/system/error_code.hpp>

#include <openssl/ssl.h>

namespace Slic3r { namespace SnapmakerMqtt {

namespace net = boost::asio;
namespace ssl = boost::asio::ssl;
using tcp     = boost::asio::ip::tcp;
using Clock   = std::chrono::steady_clock;

// MQTT 3.1.1 control packet types (high nibble of the first byte).
enum : uint8_t { CONNECT = 1, CONNACK = 2, PUBLISH = 3, PUBACK = 4, SUBSCRIBE = 8, SUBACK = 9, PINGREQ = 12, PINGRESP = 13, DISCONNECT = 14 };

namespace {

void put_u16(std::string& out, uint16_t v)
{
    out.push_back(char(v >> 8));
    out.push_back(char(v & 0xFF));
}

void put_string(std::string& out, const std::string& s)
{
    put_u16(out, uint16_t(s.size()));
    out += s;
}

uint16_t get_u16(const std::string& s, size_t pos) { return uint16_t((uint8_t(s[pos]) << 8) | uint8_t(s[pos + 1])); }

std::string packet(uint8_t first_byte, const std::string& body) { return std::string(1, char(first_byte)) + encode_remaining_length(body.size()) + body; }

} // namespace

// --- Encoding -----------------------------------------------------------------------------------

std::string encode_remaining_length(size_t length)
{
    std::string out;
    do {
        uint8_t byte = uint8_t(length % 128);
        length /= 128;
        if (length > 0)
            byte |= 0x80;
        out.push_back(char(byte));
    } while (length > 0);
    return out;
}

int decode_remaining_length(const std::string& data, size_t pos, size_t& length)
{
    length            = 0;
    size_t multiplier = 1;
    for (int i = 0; i < 4; ++i) {
        if (pos + i >= data.size())
            return 0;
        const uint8_t byte = uint8_t(data[pos + i]);
        length += size_t(byte & 0x7F) * multiplier;
        if ((byte & 0x80) == 0)
            return i + 1;
        multiplier *= 128;
    }
    return -1;
}

std::string encode_connect(const std::string& client_id, int keep_alive_s, const std::string& username, const std::string& password)
{
    std::string body;
    put_string(body, "MQTT");
    body.push_back(char(4)); // protocol level 3.1.1
    uint8_t flags = 0x02;    // clean session
    if (!username.empty())
        flags |= 0x80;
    if (!password.empty())
        flags |= 0x40;
    body.push_back(char(flags));
    put_u16(body, uint16_t(keep_alive_s));
    put_string(body, client_id);
    if (!username.empty())
        put_string(body, username);
    if (!password.empty())
        put_string(body, password);
    return packet(CONNECT << 4, body);
}

std::string encode_subscribe(uint16_t packet_id, const std::string& topic, int qos)
{
    std::string body;
    put_u16(body, packet_id);
    put_string(body, topic);
    body.push_back(char(qos & 0x03));
    return packet((SUBSCRIBE << 4) | 0x02, body);
}

std::string encode_publish(const std::string& topic, const std::string& payload, int qos, uint16_t packet_id)
{
    std::string body;
    put_string(body, topic);
    if (qos > 0)
        put_u16(body, packet_id);
    body += payload;
    return packet(uint8_t((PUBLISH << 4) | ((qos & 0x03) << 1)), body);
}

std::string encode_puback(uint16_t packet_id)
{
    std::string body;
    put_u16(body, packet_id);
    return packet(PUBACK << 4, body);
}

int take_packet(std::string& buffer, Packet& out)
{
    if (buffer.size() < 2)
        return 0;
    size_t    length = 0;
    const int n      = decode_remaining_length(buffer, 1, length);
    if (n < 0)
        return -1;
    if (n == 0 || buffer.size() < 1 + size_t(n) + length)
        return 0;
    out.type  = uint8_t(buffer[0]) >> 4;
    out.flags = uint8_t(buffer[0]) & 0x0F;
    out.body  = buffer.substr(1 + n, length);
    buffer.erase(0, 1 + n + length);
    return 1;
}

// --- Client -------------------------------------------------------------------------------------

struct Client::Impl
{
    explicit Impl(TlsConfig c) : config(std::move(c)), ctx(ssl::context::tls_client) {}

    TlsConfig                                  config;
    net::io_context                            io;
    ssl::context                               ctx;
    std::unique_ptr<ssl::stream<tcp::socket>> stream;
    std::array<char, 8192>                     chunk{};
    std::string                                rx;
    std::deque<Message>                        messages;
    std::set<uint16_t>                         acked;     // PUBACK / SUBACK ids received
    std::set<uint16_t>                         refused;   // SUBACK ids the broker refused
    int                                        connack = -1;
    bool                                       reading = false;
    bool                                       failed  = false;
    bool                                       open    = false;
    std::string                                error;
    uint16_t                                   next_id = 1;
    Clock::time_point                          last_sent = Clock::now();

    uint16_t new_id()
    {
        if (next_id == 0)
            next_id = 1;
        return next_id++;
    }

    void fail(const std::string& what)
    {
        if (!failed) {
            failed = true;
            error  = what;
        }
    }

    // Runs handlers until cond() holds, the connection fails or the deadline passes.
    bool pump_until(const std::function<bool()>& cond, Clock::time_point deadline)
    {
        while (!cond()) {
            if (failed)
                return false;
            const auto now = Clock::now();
            if (now >= deadline)
                return false;
            if (io.stopped())
                io.restart();
            io.run_one_for(deadline - now);
        }
        return true;
    }

    void handle_packet(const Packet& p)
    {
        switch (p.type) {
        case CONNACK:
            if (p.body.size() >= 2)
                connack = uint8_t(p.body[1]);
            break;
        case SUBACK:
            if (p.body.size() >= 3) {
                const uint16_t id = get_u16(p.body, 0);
                acked.insert(id);
                if (uint8_t(p.body[2]) == 0x80)
                    refused.insert(id);
            }
            break;
        case PUBACK:
            if (p.body.size() >= 2)
                acked.insert(get_u16(p.body, 0));
            break;
        case PUBLISH: {
            if (p.body.size() < 2)
                break;
            const size_t topic_len = get_u16(p.body, 0);
            size_t       pos       = 2 + topic_len;
            if (pos > p.body.size())
                break;
            Message   m;
            const int qos = (p.flags >> 1) & 0x03;
            m.topic       = p.body.substr(2, topic_len);
            if (qos > 0) {
                if (pos + 2 > p.body.size())
                    break;
                write_async(encode_puback(get_u16(p.body, pos)));
                pos += 2;
            }
            m.payload = p.body.substr(pos);
            messages.push_back(std::move(m));
            break;
        }
        default: break; // PINGRESP and anything else needs no answer
        }
    }

    void start_read()
    {
        if (reading || !stream)
            return;
        reading = true;
        stream->async_read_some(net::buffer(chunk), [this](const boost::system::error_code& ec, size_t n) {
            reading = false;
            if (ec) {
                fail("connection lost: " + ec.message());
                return;
            }
            rx.append(chunk.data(), n);
            Packet p;
            for (;;) {
                const int r = take_packet(rx, p);
                if (r < 0) {
                    fail("malformed packet from the broker");
                    return;
                }
                if (r == 0)
                    break;
                handle_packet(p);
            }
            start_read();
        });
    }

    // Queues a write; writes complete in order because each waits for the previous one.
    std::deque<std::shared_ptr<std::string>> out_queue;
    bool                                     writing = false;

    void write_async(std::string data)
    {
        out_queue.push_back(std::make_shared<std::string>(std::move(data)));
        last_sent = Clock::now();
        if (!writing)
            write_next();
    }

    void write_next()
    {
        if (out_queue.empty() || !stream) {
            writing = false;
            return;
        }
        writing   = true;
        auto data = out_queue.front();
        net::async_write(*stream, net::buffer(*data), [this, data](const boost::system::error_code& ec, size_t) {
            out_queue.pop_front();
            if (ec) {
                writing = false;
                fail("write failed: " + ec.message());
                return;
            }
            write_next();
        });
    }

    bool flush(Clock::time_point deadline) { return pump_until([this] { return !writing && out_queue.empty(); }, deadline); }

    void keep_alive()
    {
        if (open && config.keep_alive_s > 0 && Clock::now() - last_sent > std::chrono::seconds(config.keep_alive_s / 2))
            write_async(std::string{char(PINGREQ << 4), 0});
    }

    void close()
    {
        if (stream) {
            boost::system::error_code ec;
            stream->lowest_layer().cancel(ec);
            stream->lowest_layer().close(ec);
        }
        // Let the cancelled handlers run before the buffers they use go away.
        io.restart();
        io.poll();
        stream.reset();
        open = false;
    }
};

Client::Client(TlsConfig config) : m(std::make_unique<Impl>(std::move(config))) {}

Client::~Client() { disconnect(); }

bool Client::connected() const { return m->open && !m->failed; }

bool Client::connect(std::chrono::milliseconds timeout, std::string& error)
{
    const auto deadline = Clock::now() + timeout;
    auto       finish   = [&](const std::string& what) {
        error = what.empty() ? m->error : what;
        m->close();
        return false;
    };

    boost::system::error_code ec;
    m->ctx.set_options(ssl::context::default_workarounds | ssl::context::no_sslv2 | ssl::context::no_sslv3 | ssl::context::no_tlsv1 |
                       ssl::context::no_tlsv1_1);
    if (m->config.ca_pem.empty())
        m->ctx.set_default_verify_paths(ec);
    else
        m->ctx.add_certificate_authority(net::buffer(m->config.ca_pem), ec);
    if (ec)
        return finish("invalid CA certificate: " + ec.message());
    if (!m->config.cert_pem.empty()) {
        m->ctx.use_certificate_chain(net::buffer(m->config.cert_pem), ec);
        if (ec)
            return finish("invalid client certificate: " + ec.message());
        m->ctx.use_private_key(net::buffer(m->config.key_pem), ssl::context::pem, ec);
        if (ec)
            return finish("invalid client key: " + ec.message());
    }
    m->ctx.set_verify_mode(m->config.verify_peer ? ssl::verify_peer : ssl::verify_none);

    m->stream = std::make_unique<ssl::stream<tcp::socket>>(m->io, m->ctx);
    if (m->config.verify_peer)
        m->stream->set_verify_callback(ssl::host_name_verification(m->config.host));
    SSL_set_tlsext_host_name(m->stream->native_handle(), m->config.host.c_str());

    // Resolve and connect.
    tcp::resolver                 resolver(m->io);
    tcp::resolver::results_type   endpoints;
    bool                          done = false;
    resolver.async_resolve(m->config.host, std::to_string(m->config.port),
                           [&](const boost::system::error_code& e, tcp::resolver::results_type r) {
                               ec        = e;
                               endpoints = std::move(r);
                               done      = true;
                           });
    if (!m->pump_until([&] { return done; }, deadline)) {
        resolver.cancel();
        return finish("could not resolve " + m->config.host);
    }
    if (ec)
        return finish("could not resolve " + m->config.host + ": " + ec.message());

    done = false;
    net::async_connect(m->stream->lowest_layer(), endpoints, [&](const boost::system::error_code& e, const tcp::endpoint&) {
        ec   = e;
        done = true;
    });
    if (!m->pump_until([&] { return done; }, deadline))
        return finish("timed out connecting to " + m->config.host);
    if (ec)
        return finish("could not connect to " + m->config.host + ": " + ec.message());

    done = false;
    m->stream->async_handshake(ssl::stream_base::client, [&](const boost::system::error_code& e) {
        ec   = e;
        done = true;
    });
    if (!m->pump_until([&] { return done; }, deadline))
        return finish("timed out in the TLS handshake");
    if (ec)
        return finish("TLS handshake failed: " + ec.message());

    m->open = true;
    m->start_read();
    m->write_async(encode_connect(m->config.client_id, m->config.keep_alive_s, m->config.username, m->config.password));
    if (!m->pump_until([this] { return m->connack >= 0; }, deadline))
        return finish(m->failed ? std::string() : "the broker did not answer CONNECT");
    if (m->connack != 0)
        return finish("the broker refused the connection (code " + std::to_string(m->connack) + ")");
    return true;
}

bool Client::subscribe(const std::string& topic, int qos, std::chrono::milliseconds timeout, std::string& error)
{
    if (!connected()) {
        error = "not connected";
        return false;
    }
    const uint16_t id = m->new_id();
    m->write_async(encode_subscribe(id, topic, qos));
    if (!m->pump_until([this, id] { return m->acked.count(id) > 0; }, Clock::now() + timeout)) {
        error = m->failed ? m->error : "the broker did not answer SUBSCRIBE";
        return false;
    }
    if (m->refused.count(id) > 0) {
        error = "the broker refused the subscription to " + topic;
        return false;
    }
    return true;
}

bool Client::publish(const std::string& topic, const std::string& payload, int qos, std::chrono::milliseconds timeout, std::string& error)
{
    if (!connected()) {
        error = "not connected";
        return false;
    }
    const auto     deadline = Clock::now() + timeout;
    const uint16_t id       = qos > 0 ? m->new_id() : 0;
    m->write_async(encode_publish(topic, payload, qos, id));
    const bool ok = qos > 0 ? m->pump_until([this, id] { return m->acked.count(id) > 0; }, deadline) : m->flush(deadline);
    if (!ok)
        error = m->failed ? m->error : "the broker did not acknowledge the message";
    return ok;
}

bool Client::wait_message(std::chrono::milliseconds timeout, Message& message, std::string& error)
{
    const auto deadline = Clock::now() + timeout;
    while (m->messages.empty()) {
        if (!connected()) {
            error = m->failed ? m->error : "not connected";
            return false;
        }
        m->keep_alive();
        const auto step = std::min(deadline, Clock::now() + std::chrono::seconds(5));
        m->pump_until([this] { return !m->messages.empty(); }, step);
        if (m->messages.empty() && Clock::now() >= deadline) {
            error = m->failed ? m->error : "timed out waiting for a reply";
            return false;
        }
    }
    message = std::move(m->messages.front());
    m->messages.pop_front();
    return true;
}

void Client::disconnect()
{
    if (!m->stream)
        return;
    if (connected()) {
        m->write_async(std::string{char(DISCONNECT << 4), 0});
        m->flush(Clock::now() + std::chrono::seconds(2));
    }
    m->close();
}

}} // namespace Slic3r::SnapmakerMqtt
