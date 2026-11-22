#include "SecretBox.hpp"

#include <cstddef>
#include <ios>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>

#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/log/trivial.hpp>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#include <boost/nowide/fstream.hpp>
#else
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <wx/secretstore.h>
#include <wx/string.h>
#endif

namespace Slic3r { namespace SecretBox {

#ifdef _WIN32

// DPAPI output starts with the version 1 provider header.
bool is_sealed(const std::string &data) { return data.size() > 4 && data.compare(0, 4, std::string("\x01\x00\x00\x00", 4)) == 0; }

static std::string dpapi(const std::string &in, bool protect)
{
    DATA_BLOB src{static_cast<DWORD>(in.size()), reinterpret_cast<BYTE *>(const_cast<char *>(in.data()))};
    DATA_BLOB dst{0, nullptr};
    const BOOL ok = protect ? CryptProtectData(&src, L"Unified Slicer", nullptr, nullptr, nullptr, 0, &dst) :
                              CryptUnprotectData(&src, nullptr, nullptr, nullptr, nullptr, 0, &dst);
    if (!ok)
        throw std::runtime_error("DPAPI error " + std::to_string(GetLastError()));
    std::string out(reinterpret_cast<const char *>(dst.pbData), dst.cbData);
    LocalFree(dst.pbData);
    return out;
}

std::string seal(const std::string &plain, const std::string &) { return dpapi(plain, true); }

std::string open(const std::string &sealed, const std::string &) { return is_sealed(sealed) ? dpapi(sealed, false) : sealed; }

bool can_encrypt() { return true; }

void write_private_file(const std::string &path, const std::string &data)
{
    const boost::filesystem::path target(path);
    boost::filesystem::create_directories(target.parent_path());
    const boost::filesystem::path tmp = target.string() + ".part";
    {
        boost::nowide::ofstream out(tmp.string(), std::ios::binary | std::ios::trunc);
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        out.close();
        if (out.fail())
            throw std::runtime_error("could not write " + tmp.string());
    }
    boost::filesystem::rename(tmp, target);
}

#else

static const std::string MAGIC = "USB1";
constexpr size_t         KEY_LEN = 32, IV_LEN = 12, TAG_LEN = 16;

bool is_sealed(const std::string &data) { return data.size() >= MAGIC.size() + IV_LEN + TAG_LEN && data.compare(0, MAGIC.size(), MAGIC) == 0; }

// True when the keychain answers: an entry written now reads back. Load() fails the same way for a
// missing entry and for a locked or unreachable keychain, and only the first may get a new key.
static bool keychain_answers(wxSecretStore &store)
{
    const wxString service = wxString::FromUTF8("UnifiedSlicer/probe");
    if (!store.Save(service, "probe", wxSecretValue(wxString("1"))))
        return false;
    wxString      user;
    wxSecretValue value;
    const bool    ok = store.Load(service, user, value);
    store.Delete(service);
    return ok;
}

// The purpose's key from the keychain, created on first use when `create`. Empty without a keychain.
// A key found or made is kept for the session, so saving and reading sign-ins doesn't ask the
// keychain (a D-Bus call on Linux, maybe an unlock prompt) every time.
static std::string keychain_key(const std::string &purpose, bool create)
{
    static std::mutex                         cache_mutex;
    static std::map<std::string, std::string> cache;
    {
        std::lock_guard<std::mutex> lock(cache_mutex);
        if (const auto it = cache.find(purpose); it != cache.end())
            return it->second;
    }
    auto keep = [&purpose](const std::string &key) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        return cache.emplace(purpose, key).first->second;
    };
    wxSecretStore store = wxSecretStore::GetDefault();
    if (!store.IsOk()) {
        static std::mutex            mutex;
        static std::set<std::string> warned;
        std::lock_guard<std::mutex>  lock(mutex);
        if (create && warned.insert(purpose).second)
            BOOST_LOG_TRIVIAL(warning) << "SecretBox: no system keychain, so the " << purpose
                                       << " sign-in is saved unencrypted in a file only this user can read";
        return {};
    }
    const wxString service = wxString::FromUTF8("UnifiedSlicer/" + purpose);
    wxString       user;
    wxSecretValue  value;
    if (store.Load(service, user, value) && value.GetSize() == KEY_LEN)
        return keep(std::string(static_cast<const char *>(value.GetData()), value.GetSize()));
    if (!create)
        return {};
    // A new key would make everything sealed with the old one unreadable, so the keychain has to
    // show it is unlocked and really has no key first.
    if (!keychain_answers(store))
        throw std::runtime_error("the system keychain is locked or not answering");
    std::string key(KEY_LEN, '\0');
    if (RAND_bytes(reinterpret_cast<unsigned char *>(&key[0]), int(KEY_LEN)) != 1)
        throw std::runtime_error("no random bytes for the keychain key");
    if (!store.Save(service, "key", wxSecretValue(key.size(), key.data())))
        return {};
    return keep(key);
}

std::string seal(const std::string &plain, const std::string &purpose)
{
    const std::string key = keychain_key(purpose, true);
    if (key.empty())
        return plain;
    std::string iv(IV_LEN, '\0');
    if (RAND_bytes(reinterpret_cast<unsigned char *>(&iv[0]), int(IV_LEN)) != 1)
        throw std::runtime_error("no random bytes for the IV");
    std::string cipher(plain.size(), '\0'), tag(TAG_LEN, '\0');
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int             len = 0, total = 0;
    const bool      ok  = ctx != nullptr && EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
                    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, int(IV_LEN), nullptr) == 1 &&
                    EVP_EncryptInit_ex(ctx, nullptr, nullptr, reinterpret_cast<const unsigned char *>(key.data()),
                                       reinterpret_cast<const unsigned char *>(iv.data())) == 1 &&
                    EVP_EncryptUpdate(ctx, reinterpret_cast<unsigned char *>(&cipher[0]), &len,
                                      reinterpret_cast<const unsigned char *>(plain.data()), int(plain.size())) == 1 &&
                    (total = len, EVP_EncryptFinal_ex(ctx, reinterpret_cast<unsigned char *>(&cipher[0]) + total, &len) == 1) &&
                    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, int(TAG_LEN), &tag[0]) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        throw std::runtime_error("encrypting the saved sign-in failed");
    return MAGIC + iv + tag + cipher;
}

std::string open(const std::string &sealed, const std::string &purpose)
{
    if (!is_sealed(sealed))
        return sealed;
    const std::string key = keychain_key(purpose, false);
    if (key.empty())
        throw std::runtime_error("the keychain key for the saved sign-in is missing");
    const std::string iv     = sealed.substr(MAGIC.size(), IV_LEN);
    std::string       tag    = sealed.substr(MAGIC.size() + IV_LEN, TAG_LEN);
    const std::string cipher = sealed.substr(MAGIC.size() + IV_LEN + TAG_LEN);
    std::string       plain(cipher.size(), '\0');
    EVP_CIPHER_CTX   *ctx = EVP_CIPHER_CTX_new();
    int               len = 0;
    const bool        ok  = ctx != nullptr && EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
                    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, int(IV_LEN), nullptr) == 1 &&
                    EVP_DecryptInit_ex(ctx, nullptr, nullptr, reinterpret_cast<const unsigned char *>(key.data()),
                                       reinterpret_cast<const unsigned char *>(iv.data())) == 1 &&
                    EVP_DecryptUpdate(ctx, reinterpret_cast<unsigned char *>(&plain[0]), &len,
                                      reinterpret_cast<const unsigned char *>(cipher.data()), int(cipher.size())) == 1 &&
                    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, int(TAG_LEN), &tag[0]) == 1 &&
                    EVP_DecryptFinal_ex(ctx, reinterpret_cast<unsigned char *>(&plain[0]) + len, &len) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        throw std::runtime_error("the saved sign-in could not be decrypted");
    return plain;
}

bool can_encrypt() { return wxSecretStore::GetDefault().IsOk(); }

void write_private_file(const std::string &path, const std::string &data)
{
    const boost::filesystem::path target(path);
    boost::filesystem::create_directories(target.parent_path());
    const std::string tmp = target.string() + ".part";
    // Created owner-only, so the text is never readable by others, not even before a chmod.
    const int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (fd < 0)
        throw std::runtime_error("could not create " + tmp + ": " + std::strerror(errno));
    // An existing file keeps its old mode through O_CREAT.
    bool        ok   = ::fchmod(fd, S_IRUSR | S_IWUSR) == 0;
    const char *next = data.data();
    size_t      left = data.size();
    while (ok && left > 0) {
        const ssize_t n = ::write(fd, next, left);
        if (n < 0 && errno == EINTR)
            continue;
        ok = n > 0;
        if (ok) {
            next += n;
            left -= size_t(n);
        }
    }
    ok = ::close(fd) == 0 && ok;
    if (!ok) {
        ::unlink(tmp.c_str());
        throw std::runtime_error("could not write " + tmp);
    }
    boost::filesystem::rename(tmp, target);
}

#endif

}} // namespace Slic3r::SecretBox
