#include "UpdateSignature.hpp"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <memory>
#include <sstream>
#include <string>

#include <openssl/evp.h>
#include <openssl/ossl_typ.h> // IWYU pragma: keep

namespace Slic3r { namespace UpdateSignature {

const char* const RELEASE_PUBLIC_KEY = "euCEHkJGOno8WWZqB9JtG2zO6H8+a4pLdc1D0SDJfrY=";

namespace {

std::string trim(const std::string& s)
{
    const auto first = std::find_if_not(s.begin(), s.end(), [](unsigned char c) { return std::isspace(c); });
    const auto last  = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    return first < last ? std::string(first, last) : std::string();
}

// Empty when `text` is not padded base64.
std::string base64_decode(const std::string& text)
{
    const std::string in = trim(text);
    if (in.empty() || in.size() % 4 != 0)
        return {};
    std::string out(in.size() / 4 * 3, '\0');
    const int   len = EVP_DecodeBlock(reinterpret_cast<unsigned char*>(&out[0]), reinterpret_cast<const unsigned char*>(in.data()),
                                      static_cast<int>(in.size()));
    if (len < 0)
        return {};
    // EVP_DecodeBlock counts the padding as zero bytes.
    const size_t padding = in.size() >= 2 && in[in.size() - 2] == '=' ? 2 : in.back() == '=' ? 1 : 0;
    out.resize(static_cast<size_t>(len) - padding);
    return out;
}

} // namespace

bool verify(const std::string& message, const std::string& signature_base64, const std::string& public_key_base64)
{
    const std::string key       = base64_decode(public_key_base64);
    const std::string signature = base64_decode(signature_base64);
    if (key.size() != 32 || signature.size() != 64)
        return false;
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> pkey(
        EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nullptr, reinterpret_cast<const unsigned char*>(key.data()), key.size()),
        &EVP_PKEY_free);
    std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> ctx(EVP_MD_CTX_new(), &EVP_MD_CTX_free);
    // Ed25519 signs the whole message in one pass, so there is no digest to name.
    return pkey && ctx && EVP_DigestVerifyInit(ctx.get(), nullptr, nullptr, nullptr, pkey.get()) == 1 &&
           EVP_DigestVerify(ctx.get(), reinterpret_cast<const unsigned char*>(signature.data()), signature.size(),
                            reinterpret_cast<const unsigned char*>(message.data()), message.size()) == 1;
}

bool parse_checksum(const std::string& body, std::string& digest, std::string& file_name)
{
    std::istringstream ss(body);
    std::string        line;
    std::getline(ss, line);
    std::istringstream fields(line);
    std::string        hex, name;
    fields >> hex;
    std::getline(fields, name);
    name = trim(name);
    // sha256sum marks a file read in binary mode with '*'.
    if (!name.empty() && name.front() == '*')
        name.erase(0, 1);
    std::transform(hex.begin(), hex.end(), hex.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    if (hex.size() != 64 || !std::all_of(hex.begin(), hex.end(), [](unsigned char c) { return std::isxdigit(c) != 0; }) || name.empty())
        return false;
    digest    = hex;
    file_name = name;
    return true;
}

}} // namespace Slic3r::UpdateSignature
