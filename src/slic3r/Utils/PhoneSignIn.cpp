#include "PhoneSignIn.hpp"

#include "SecretBox.hpp"
#include "libslic3r/Utils.hpp"

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <exception>
#include <ios>
#include <istream>
#include <iterator>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <boost/asio/buffer.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ip/udp.hpp>
#include <boost/asio/read_until.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/streambuf.hpp>
#include <boost/asio/write.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/fstream.hpp>
#include <boost/system/error_code.hpp>

#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <openssl/rand.h>

namespace Slic3r { namespace PhoneSignIn {

using nlohmann::json;
namespace asio = boost::asio;
using asio::ip::tcp;

namespace {

constexpr size_t KEY_LEN = 32, NONCE_LEN = 12, TAG_LEN = 16, ID_LEN = 16;
// Requests that aren't the offer (a port scan, a stale code) before the offer is withdrawn.
constexpr int MAX_BAD_REQUESTS = 30;
const char*   AAD_PREFIX       = "unified-signin-v1:";

std::string random_bytes(size_t n)
{
    std::string out(n, '\0');
    if (RAND_bytes(reinterpret_cast<unsigned char*>(&out[0]), static_cast<int>(n)) != 1)
        throw std::runtime_error("no random bytes");
    return out;
}

boost::filesystem::path bambu_file() { return boost::filesystem::path(data_dir()) / "bambu_phone_session.bin"; }

std::mutex& bambu_mutex()
{
    static std::mutex m;
    return m;
}

std::string json_string(const json& j, const char* key)
{
    const auto it = j.find(key);
    if (it == j.end())
        return {};
    if (it->is_string())
        return it->get<std::string>();
    if (it->is_number_integer())
        return std::to_string(it->get<long long>());
    return {};
}

// This computer's IPv4 addresses a phone on the same network may reach, the default route's first.
std::vector<std::string> local_ipv4s()
{
    std::vector<std::string> out;
    auto add = [&out](const asio::ip::address& a) {
        if (!a.is_v4() || a.is_loopback() || a.is_unspecified())
            return;
        const auto b = a.to_v4().to_bytes();
        if (b[0] == 169 && b[1] == 254) // link-local: no DHCP answer
            return;
        const std::string s = a.to_string();
        if (std::find(out.begin(), out.end(), s) == out.end())
            out.push_back(s);
    };
    try {
        // Connecting a UDP socket sends nothing; it only picks the interface of the default route.
        asio::io_context      io;
        asio::ip::udp::socket s(io);
        s.connect(asio::ip::udp::endpoint(asio::ip::make_address("192.0.2.1"), 9));
        add(s.local_endpoint().address());
    } catch (const std::exception&) {}
    try {
        asio::io_context io;
        tcp::resolver    resolver(io);
        for (const auto& e : resolver.resolve(asio::ip::host_name(), ""))
            add(e.endpoint().address());
    } catch (const std::exception&) {}
    if (out.size() > 4)
        out.resize(4);
    return out;
}

} // namespace

std::string base64url(const std::string& bytes)
{
    static const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string        out;
    unsigned int       acc = 0;
    int                bits = 0;
    for (unsigned char c : bytes) {
        acc = (acc << 8) | c;
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            out.push_back(chars[(acc >> bits) & 0x3F]);
        }
    }
    if (bits > 0)
        out.push_back(chars[(acc << (6 - bits)) & 0x3F]);
    return out;
}

std::string seal(const std::string& key, const std::string& plain, const std::string& aad)
{
    if (key.size() != KEY_LEN)
        throw std::runtime_error("bad key");
    const std::string nonce = random_bytes(NONCE_LEN);
    std::string       out   = nonce;
    out.resize(NONCE_LEN + plain.size() + TAG_LEN);

    std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> ctx(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
    auto  u   = [](const std::string& s) { return reinterpret_cast<const unsigned char*>(s.data()); };
    auto* dst = reinterpret_cast<unsigned char*>(&out[NONCE_LEN]);
    int   len = 0, total = 0;
    bool  ok  = ctx && EVP_EncryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, NONCE_LEN, nullptr) == 1 &&
              EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, u(key), u(nonce)) == 1 &&
              EVP_EncryptUpdate(ctx.get(), nullptr, &len, u(aad), static_cast<int>(aad.size())) == 1 &&
              EVP_EncryptUpdate(ctx.get(), dst, &len, u(plain), static_cast<int>(plain.size())) == 1;
    total = len;
    ok    = ok && EVP_EncryptFinal_ex(ctx.get(), dst + total, &len) == 1;
    total += len;
    ok = ok && EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_GET_TAG, TAG_LEN, dst + total) == 1;
    if (!ok || static_cast<size_t>(total) != plain.size())
        throw std::runtime_error("encryption failed");
    return out;
}

// ---- Bambu session -------------------------------------------------------------------------------

void remember_bambu_login(const std::string& user_login_message)
{
    try {
        const json j = json::parse(user_login_message, nullptr, false);
        if (!j.is_object() || !j.contains("data") || !j["data"].is_object())
            return;
        const json& d = j["data"];
        BambuSession s;
        s.access_token  = json_string(d, "token");
        s.refresh_token = json_string(d, "refresh_token");
        if (d.contains("user") && d["user"].is_object()) {
            s.user_id = json_string(d["user"], "uid");
            s.name    = json_string(d["user"], "name");
            if (s.name.empty())
                s.name = json_string(d["user"], "account");
        }
        if (s.access_token.empty() || s.user_id.empty())
            return;
        const json out = {{"access_token", s.access_token}, {"refresh_token", s.refresh_token}, {"user_id", s.user_id}, {"name", s.name}};
        const std::string sealed = SecretBox::seal(out.dump(), "bambu");

        std::lock_guard<std::mutex> lock(bambu_mutex());
        boost::nowide::ofstream     f(bambu_file().string(), std::ios::binary | std::ios::trunc);
        f.write(sealed.data(), static_cast<std::streamsize>(sealed.size()));
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "PhoneSignIn: could not keep the Bambu session: " << e.what();
    }
}

void forget_bambu_login()
{
    std::lock_guard<std::mutex> lock(bambu_mutex());
    boost::system::error_code   ec;
    boost::filesystem::remove(bambu_file(), ec);
}

BambuSession bambu_session()
{
    BambuSession s;
    try {
        std::string data;
        {
            std::lock_guard<std::mutex> lock(bambu_mutex());
            boost::nowide::ifstream     f(bambu_file().string(), std::ios::binary);
            if (!f)
                return s;
            data.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
        }
        const json j = json::parse(SecretBox::open(data, "bambu"), nullptr, false);
        if (!j.is_object())
            return s;
        s.access_token  = json_string(j, "access_token");
        s.refresh_token = json_string(j, "refresh_token");
        s.user_id       = json_string(j, "user_id");
        s.name          = json_string(j, "name");
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "PhoneSignIn: could not read the Bambu session: " << e.what();
    }
    return s;
}

// ---- Server --------------------------------------------------------------------------------------

struct Server::Impl
{
    asio::io_context   io;
    tcp::acceptor      acceptor{io};
    asio::steady_timer expiry{io};
    std::thread        thread;
    std::atomic<State> state{State::Idle};
    std::string        id;
    std::string        body; // sealed payload; wiped once delivered or withdrawn
    std::string        qr;
    int                bad_requests{0};

    void finish(State end)
    {
        if (state != State::Waiting)
            return;
        state = end;
        body.assign(body.size(), '\0');
        body.clear();
        boost::system::error_code ec;
        acceptor.close(ec);
        expiry.cancel();
    }

    void accept()
    {
        acceptor.async_accept([this](const boost::system::error_code& ec, tcp::socket socket) {
            if (ec || state != State::Waiting)
                return;
            serve(std::make_shared<tcp::socket>(std::move(socket)));
            accept();
        });
    }

    void serve(std::shared_ptr<tcp::socket> socket)
    {
        auto buf      = std::make_shared<asio::streambuf>(8192);
        auto deadline = std::make_shared<asio::steady_timer>(io, std::chrono::seconds(10));
        deadline->async_wait([socket](const boost::system::error_code& ec) {
            if (!ec) {
                boost::system::error_code ignored;
                socket->close(ignored);
            }
        });
        asio::async_read_until(*socket, *buf, "\r\n\r\n", [this, socket, buf, deadline](const boost::system::error_code& ec, size_t) {
            if (ec) {
                deadline->cancel();
                return;
            }
            std::istream in(buf.get());
            std::string  request_line;
            std::getline(in, request_line);
            const std::string wanted = "GET /signin/" + id + " HTTP/";
            const bool        match  = state == State::Waiting && request_line.compare(0, wanted.size(), wanted) == 0;
            if (!match && ++bad_requests >= MAX_BAD_REQUESTS)
                finish(State::Failed);

            std::ostringstream head;
            if (match)
                head << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " << body.size()
                     << "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
            else
                head << "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            auto response = std::make_shared<std::string>(head.str() + (match ? body : std::string()));
            asio::async_write(*socket, asio::buffer(*response),
                              [this, socket, response, deadline, match](const boost::system::error_code& ec, size_t) {
                                  deadline->cancel();
                                  response->assign(response->size(), '\0');
                                  boost::system::error_code ignored;
                                  socket->shutdown(tcp::socket::shutdown_both, ignored);
                                  socket->close(ignored);
                                  // A dropped connection leaves the offer up for the phone's retry.
                                  if (match && !ec)
                                      finish(State::Delivered);
                              });
        });
    }
};

Server::Server() = default;
Server::~Server() { stop(); }

bool Server::start(const std::string& payload, std::chrono::seconds lifetime, std::string& error)
{
    stop();
    m = std::make_unique<Impl>();
    try {
        const std::vector<std::string> hosts = local_ipv4s();
        if (hosts.empty()) {
            error = "no network";
            m.reset();
            return false;
        }
        const std::string key = random_bytes(KEY_LEN);
        m->id                 = base64url(random_bytes(ID_LEN));
        m->body               = seal(key, payload, AAD_PREFIX + m->id);

        m->acceptor.open(tcp::v4());
        m->acceptor.bind(tcp::endpoint(tcp::v4(), 0));
        m->acceptor.listen();
        const unsigned short port = m->acceptor.local_endpoint().port();

        std::string h;
        for (const std::string& host : hosts)
            h += (h.empty() ? "" : ",") + host;
        m->qr = "unifiedslicer://signin?v=1&h=" + h + "&p=" + std::to_string(port) + "&i=" + m->id + "&k=" + base64url(key);

        m->state = State::Waiting;
        m->expiry.expires_after(lifetime);
        Impl* impl = m.get();
        m->expiry.async_wait([impl](const boost::system::error_code& ec) {
            if (!ec)
                impl->finish(State::Expired);
        });
        m->accept();
        m->thread = std::thread([impl] {
            try {
                impl->io.run();
            } catch (const std::exception& e) {
                BOOST_LOG_TRIVIAL(error) << "PhoneSignIn: server stopped: " << e.what();
                impl->state = State::Failed;
            }
        });
        BOOST_LOG_TRIVIAL(info) << "PhoneSignIn: offering sign-ins on port " << port;
        return true;
    } catch (const std::exception& e) {
        error = e.what();
        m.reset();
        return false;
    }
}

void Server::stop()
{
    if (!m)
        return;
    Impl* impl = m.get();
    impl->io.stop();
    if (impl->thread.joinable())
        impl->thread.join();
    impl->body.assign(impl->body.size(), '\0');
    m.reset();
}

Server::State Server::state() const { return m ? m->state.load() : State::Idle; }

std::string Server::qr_text() const { return m ? m->qr : std::string(); }

}} // namespace Slic3r::PhoneSignIn
