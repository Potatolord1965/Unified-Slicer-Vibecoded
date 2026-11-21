#pragma once

#include <string>

namespace Slic3r { namespace UpdateSignature {

// Base64 of the raw Ed25519 public key whose private half (the UPDATE_SIGNING_KEY secret of
// release_unified.yml) signs the checksum file of every Unified Slicer release.
extern const char* const RELEASE_PUBLIC_KEY;

// True when `signature_base64` is an Ed25519 signature of `message` by `public_key_base64`.
bool verify(const std::string& message, const std::string& signature_base64, const std::string& public_key_base64 = RELEASE_PUBLIC_KEY);

// Reads a sha256sum line, "<64 hex digits>  <file name>". Fills `digest` (lower case) and
// `file_name`, and returns false unless both are present.
bool parse_checksum(const std::string& body, std::string& digest, std::string& file_name);

}} // namespace Slic3r::UpdateSignature
