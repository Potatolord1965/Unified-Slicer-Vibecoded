#include <catch2/catch_test_macros.hpp>

#include <map>
#include <string>

#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <nlohmann/json.hpp>

#include "libslic3r/Utils.hpp"
#include "slic3r/GUI/DeviceHub/CloudAccounts.hpp"

using Slic3r::GUI::CloudAccountSet;

namespace {

// A service with one signed-in account at a time, like the real ones: `active` is the user id the
// service is signed in as, `tokens` what each user's sign-in holds.
struct FakeService
{
    std::string                        active;
    std::map<std::string, std::string> tokens;
    int                                detached{0};

    CloudAccountSet::Hooks hooks()
    {
        CloudAccountSet::Hooks h;
        h.active_key   = [this] { return active; };
        h.active_label = [this] { return active.empty() ? std::string() : "User " + active; };
        h.capture      = [this]() -> nlohmann::json { return {{"user", active}, {"token", tokens[active]}}; };
        h.apply        = [this](const nlohmann::json& d) {
            active = d.value("user", std::string());
            return !active.empty();
        };
        h.detach = [this] {
            active.clear();
            ++detached;
        };
        return h;
    }
};

struct TempDataDir
{
    std::string previous = Slic3r::data_dir();
    TempDataDir()
    {
        const auto dir = boost::filesystem::temp_directory_path() / boost::filesystem::unique_path("cloud-accounts-%%%%-%%%%");
        boost::filesystem::create_directories(dir);
        Slic3r::set_data_dir(dir.string());
    }
    ~TempDataDir()
    {
        boost::system::error_code ec;
        boost::filesystem::remove_all(Slic3r::data_dir(), ec);
        Slic3r::set_data_dir(previous);
    }
};

} // namespace

TEST_CASE("Cloud accounts: adding, switching and signing out", "[CloudAccounts]")
{
    TempDataDir    dir;
    FakeService    svc;
    svc.active    = "a";
    svc.tokens    = {{"a", "ta"}, {"b", "tb"}};
    CloudAccountSet set("test", svc.hooks());

    // The account signed in before is kept on first look.
    REQUIRE(set.accounts().size() == 1);

    // Adding one sets the current one aside while the sign-in runs, and keeps both.
    set.add([&svc] { svc.active = "b"; });
    CHECK(svc.detached == 1);
    CHECK(svc.active == "b");
    REQUIRE(set.accounts().size() == 2);

    // Switching signs the service in with the saved sign-in.
    REQUIRE(set.switch_to("a"));
    CHECK(svc.active == "a");
    CHECK_FALSE(set.switch_to("unknown"));
    CHECK(svc.active == "a");

    // Accounts survive a restart.
    {
        CloudAccountSet again("test", svc.hooks());
        CHECK(again.accounts().size() == 2);
    }

    // Signing out of the active account makes the other one active.
    bool signed_out = false;
    set.remove("a", [&] {
        signed_out = true;
        svc.active.clear();
    });
    CHECK(signed_out);
    CHECK(svc.active == "b");
    REQUIRE(set.accounts().size() == 1);
    CHECK(set.accounts().front().key == "b");
}

TEST_CASE("Cloud accounts: a cancelled sign-in goes back to the account in use", "[CloudAccounts]")
{
    TempDataDir    dir;
    FakeService    svc;
    svc.active = "a";
    CloudAccountSet set("test", svc.hooks());

    set.add([] { /* the user closed the sign-in window */ });
    CHECK(svc.active == "a");
    CHECK(set.accounts().size() == 1);
}

TEST_CASE("Cloud accounts: refreshed tokens of an account not in use are kept", "[CloudAccounts]")
{
    TempDataDir    dir;
    FakeService    svc;
    svc.active = "a";
    CloudAccountSet set("test", svc.hooks());
    set.add([&svc] { svc.active = "b"; });

    set.update("a", {{"user", "a"}, {"token", "new"}});
    for (const auto& acc : set.accounts())
        if (acc.key == "a")
            CHECK(acc.data.value("token", std::string()) == "new");
}
