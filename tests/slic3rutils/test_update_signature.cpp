#include <catch2/catch_test_macros.hpp>

#include <string>

#include "slic3r/Utils/UpdateSignature.hpp"

using namespace Slic3r;

namespace {

// sha256sum of a 4-byte package, signed with the release key by the commands release_unified.yml runs.
const std::string CHECKSUM  = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  UnifiedSlicer-9.9.9-win64.zip\n";
const std::string SIGNATURE = "wwFR96Vg5ZyH4orn/v9I2y9ExC0JmvgWK4hkkm74jRp/DnTfYjqaGRq3UWY7Kc9ipu/pdzahDo2ygowyLRSxCQ==";

} // namespace

TEST_CASE("A checksum file signed with the release key verifies", "[UpdateSignature]")
{
    CHECK(UpdateSignature::verify(CHECKSUM, SIGNATURE));
    // The signature file may end in a newline.
    CHECK(UpdateSignature::verify(CHECKSUM, SIGNATURE + "\n"));
}

TEST_CASE("A changed checksum file or signature does not verify", "[UpdateSignature]")
{
    std::string changed = CHECKSUM;
    changed[0]          = '8';
    CHECK_FALSE(UpdateSignature::verify(changed, SIGNATURE));
    CHECK_FALSE(UpdateSignature::verify("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  UnifiedSlicer-1.0.0-win64.zip\n", SIGNATURE));

    std::string bad_sig = SIGNATURE;
    bad_sig[10]         = bad_sig[10] == 'A' ? 'B' : 'A';
    CHECK_FALSE(UpdateSignature::verify(CHECKSUM, bad_sig));
    CHECK_FALSE(UpdateSignature::verify(CHECKSUM, ""));
    CHECK_FALSE(UpdateSignature::verify(CHECKSUM, "not base64"));
}

TEST_CASE("Another key's signature does not verify", "[UpdateSignature]")
{
    // A valid Ed25519 public key that is not the release key.
    const std::string other_key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";
    CHECK_FALSE(UpdateSignature::verify(CHECKSUM, SIGNATURE, other_key));
    CHECK_FALSE(UpdateSignature::verify(CHECKSUM, SIGNATURE, "short"));
}

TEST_CASE("Checksum lines are read with their file name", "[UpdateSignature]")
{
    std::string digest, name;
    REQUIRE(UpdateSignature::parse_checksum(CHECKSUM, digest, name));
    CHECK(digest == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08");
    CHECK(name == "UnifiedSlicer-9.9.9-win64.zip");

    REQUIRE(UpdateSignature::parse_checksum("9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08 *pkg.zip\r\n", digest, name));
    CHECK(digest == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08");
    CHECK(name == "pkg.zip");

    CHECK_FALSE(UpdateSignature::parse_checksum("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\n", digest, name));
    CHECK_FALSE(UpdateSignature::parse_checksum("9f86d0  pkg.zip\n", digest, name));
    CHECK_FALSE(UpdateSignature::parse_checksum("", digest, name));
}
