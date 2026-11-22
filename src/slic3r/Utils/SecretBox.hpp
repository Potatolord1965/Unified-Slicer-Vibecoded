#pragma once

#include <string>

namespace Slic3r {

// Encrypts saved sign-ins (tokens, API keys) for the current user.
//
// Windows: DPAPI. macOS and Linux: AES-256-GCM with a random key kept in the system keychain
// (wxSecretStore: Keychain, or the Secret Service on Linux), one key per purpose. Without a
// keychain the text is returned as it is, so the caller's owner-only file is the protection.
//
// open() returns text that was never sealed (a file from an earlier build) unchanged, so callers
// read old files and seal them on the next save. Both throw std::runtime_error on failure, also
// while the keychain is locked: a new key is only made when the keychain answers and has none.
namespace SecretBox {
std::string seal(const std::string &plain, const std::string &purpose);
std::string open(const std::string &sealed, const std::string &purpose);
// True when seal() output starts the way this build writes it on this platform.
bool        is_sealed(const std::string &data);
// False when seal() can't encrypt here (no system keychain outside Windows): saved sign-ins are
// then protected only by their owner-only files.
bool        can_encrypt();
// Writes `data` to `path` through a temporary file, readable and writable by the current user only
// (mode 0600; on Windows the user profile's permissions apply). Throws std::runtime_error.
void        write_private_file(const std::string &path, const std::string &data);
} // namespace SecretBox

} // namespace Slic3r
