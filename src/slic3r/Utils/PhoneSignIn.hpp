#pragma once

#include <chrono>
#include <memory>
#include <string>

// Hands this computer's cloud sign-ins to the Unified Monitor phone app: the computer serves them
// once, encrypted, on the local network, and shows a QR code holding the address and the key.
// See docs/HLSD/phone-sign-in.md.
namespace Slic3r { namespace PhoneSignIn {

// Bambu's networking plugin keeps its tokens to itself, so the session its sign-in page reports
// (the "user_login" message) is also kept here, sealed with SecretBox, for the phone.
struct BambuSession
{
    std::string access_token;
    std::string refresh_token;
    std::string user_id;
    std::string name;
    // The whole "user_login" message, to sign the plugin in to this account again (account switching).
    std::string login_message;
};
void         remember_bambu_login(const std::string& user_login_message);
void         forget_bambu_login();
BambuSession bambu_session();

// AES-256-GCM with a 32-byte key: 12-byte nonce, ciphertext, 16-byte tag. Throws std::runtime_error.
std::string seal(const std::string& key, const std::string& plain, const std::string& aad);
std::string base64url(const std::string& bytes);

// Serves one payload, once, to the phone that scanned qr_text(); then closes. Runs on its own thread.
class Server
{
public:
    enum class State { Idle, Waiting, Delivered, Expired, Failed };

    Server();
    ~Server();
    Server(const Server&)            = delete;
    Server& operator=(const Server&) = delete;

    // Seals `payload` with a new key and listens on a free port for `lifetime`, answering only
    // phones on this computer's private networks. Any earlier offer is withdrawn. False with
    // `error` when nothing could be served (no private network, no port).
    bool        start(const std::string& payload, std::chrono::seconds lifetime, std::string& error);
    void        stop();
    State       state() const;
    // unifiedslicer://signin?v=1&h=<IPv4s>&p=<port>&i=<id>&k=<key>
    std::string qr_text() const;
    // The address of the device that took the offer, once Delivered.
    std::string delivered_to() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

}} // namespace Slic3r::PhoneSignIn
