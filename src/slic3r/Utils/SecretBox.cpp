#include "SecretBox.hpp"

#include <cstddef>
#include <stdexcept>
#include <string>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#else
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

#else

static const std::string MAGIC = "USB1";
constexpr size_t         KEY_LEN = 32, IV_LEN = 12, TAG_LEN = 16;

bool is_sealed(const std::string &data) { return data.size() >= MAGIC.size() + IV_LEN + TAG_LEN && data.compare(0, MAGIC.size(), MAGIC) == 0; }

// The purpose's key from the keychain, created on first use when `create`. Empty without a keychain.
static std::string keychain_key(const std::string &purpose, bool create)
{
    wxSecretStore store = wxSecretStore::GetDefault();
    if (!store.IsOk())
        return {};
    const wxString service = wxString::FromUTF8("UnifiedSlicer/" + purpose);
    wxString       user;
    wxSecretValue  value;
    if (store.Load(service, user, value) && value.GetSize() == KEY_LEN)
        return std::string(static_cast<const char *>(value.GetData()), value.GetSize());
    if (!create)
        return {};
    std::string key(KEY_LEN, '\0');
    if (RAND_bytes(reinterpret_cast<unsigned char *>(&key[0]), int(KEY_LEN)) != 1)
        throw std::runtime_error("no random bytes for the keychain key");
    if (!store.Save(service, "key", wxSecretValue(key.size(), key.data())))
        return {};
    return key;
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

#endif

}} // namespace Slic3r::SecretBox
