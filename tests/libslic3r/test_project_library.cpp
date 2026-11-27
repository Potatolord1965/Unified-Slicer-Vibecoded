#include <catch2/catch_all.hpp>
#include <catch2/catch_test_macros.hpp>

#include <ctime>
#include <ios>
#include <string>
#include <vector>

#include <boost/filesystem.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/nowide/fstream.hpp>
#include <boost/system/error_code.hpp>
#include <miniz.h>

#include "libslic3r/AppConfig.hpp"
#include "libslic3r/ProjectLibrary.hpp"
#include "libslic3r/miniz_extension.hpp"

using namespace Slic3r;
using namespace Slic3r::ProjectLibrary;
namespace fs = boost::filesystem;

namespace {

struct TempTree
{
    fs::path path;
    TempTree()
    {
        path = fs::temp_directory_path() / fs::unique_path("project-library-%%%%-%%%%");
        fs::create_directories(path);
    }
    ~TempTree()
    {
        boost::system::error_code ec;
        fs::remove_all(path, ec);
    }
};

void write_zip(const fs::path &file, const std::vector<std::string> &entries, std::time_t modified)
{
    fs::create_directories(file.parent_path());
    mz_zip_archive zip;
    mz_zip_zero_struct(&zip);
    REQUIRE(open_zip_writer(&zip, file.string()));
    for (const std::string &name : entries)
        REQUIRE(mz_zip_writer_add_mem(&zip, name.c_str(), "x", 1, MZ_DEFAULT_COMPRESSION));
    REQUIRE(mz_zip_writer_finalize_archive(&zip));
    REQUIRE(close_zip_writer(&zip));
    fs::last_write_time(file, modified);
}

void write_orca_project(const fs::path &file, std::time_t modified)
{
    write_zip(file, {"3D/3dmodel.model", "Metadata/project_settings.config", "Metadata/model_settings.config"}, modified);
}

void write_text(const fs::path &file, const std::string &text)
{
    fs::create_directories(file.parent_path());
    boost::nowide::ofstream(file.string(), std::ios::binary) << text;
}

std::vector<std::string> paths_of(const std::vector<Project> &projects)
{
    std::vector<std::string> out;
    for (const Project &p : projects)
        out.push_back(fs::path(p.path).filename().string());
    return out;
}

} // namespace

TEST_CASE("Project files are 3MFs a slicer saved with its settings", "[ProjectLibrary]")
{
    TempTree tmp;
    write_orca_project(tmp.path / "orca.3mf", 1000);
    write_zip(tmp.path / "prusa.3mf", {"3D/3dmodel.model", "Metadata/Slic3r_PE.config"}, 1000);
    write_zip(tmp.path / "model.3mf", {"3D/3dmodel.model"}, 1000);
    write_orca_project(tmp.path / "plate.gcode.3mf", 1000);
    write_text(tmp.path / "broken.3mf", "not a zip");

    CHECK(is_project_file(tmp.path / "orca.3mf"));
    CHECK(is_project_file(tmp.path / "prusa.3mf"));
    CHECK_FALSE(is_project_file(tmp.path / "model.3mf"));
    CHECK_FALSE(is_project_file(tmp.path / "plate.gcode.3mf"));
    CHECK_FALSE(is_project_file(tmp.path / "broken.3mf"));
    CHECK_FALSE(is_project_file(tmp.path / "missing.3mf"));
}

TEST_CASE("All projects merges the chosen folders with the slicers' recent lists", "[ProjectLibrary]")
{
    TempTree tmp;
    const fs::path folder = tmp.path / "Projects";
    write_orca_project(folder / "a.3mf", 3000);
    write_orca_project(folder / "sub" / "deep" / "b.3mf", 1000);
    write_zip(folder / "model.3mf", {"3D/3dmodel.model"}, 5000);   // not a project
    write_orca_project(folder / ".hidden" / "c.3mf", 6000);        // hidden folder
    write_text(folder / "notes.txt", "x");
    write_orca_project(tmp.path / "Elsewhere" / "d.3mf", 2000);

    const std::vector<RecentList> recent = {
        {"Unified Slicer", {(tmp.path / "Elsewhere" / "d.3mf").string(), (folder / "a.3mf").string()}},
        // Bambu Studio lists a.3mf too, spelled differently, and a file that no longer exists.
        {"Bambu Studio", {(folder / "sub" / ".." / "a.3mf").string(), (tmp.path / "gone.3mf").string()}},
    };

    const std::vector<Project> projects = collect({folder.string()}, recent);

    // Newest first, each file once; the plain model, the hidden folder and the missing file are left out.
    REQUIRE(paths_of(projects) == std::vector<std::string>{"a.3mf", "d.3mf", "b.3mf"});
    CHECK(projects[0].modified == 3000);
    CHECK(projects[0].opened_in == std::vector<std::string>{"Unified Slicer", "Bambu Studio"});
    CHECK(projects[1].opened_in == std::vector<std::string>{"Unified Slicer"});
    CHECK(projects[2].opened_in.empty());
}

TEST_CASE("The folder search respects its limits", "[ProjectLibrary]")
{
    TempTree tmp;
    write_orca_project(tmp.path / "top.3mf", 2000);
    write_orca_project(tmp.path / "l1" / "l2" / "deep.3mf", 1000);

    ScanLimits shallow;
    shallow.max_depth = 2; // the chosen folder and the folders directly in it
    CHECK(paths_of(collect({tmp.path.string()}, {}, shallow)) == std::vector<std::string>{"top.3mf"});

    ScanLimits few;
    few.max_projects = 1;
    CHECK(collect({tmp.path.string()}, {}, few).size() == 1);

    CHECK(collect({tmp.path.string()}, {}, {}, [] { return true; }).empty());
    CHECK(collect({(tmp.path / "missing").string()}, {}).empty());
}

TEST_CASE("The project folders are kept in the app config in order", "[ProjectLibrary][AppConfig]")
{
    AppConfig config;
    CHECK(config.get_project_folders().empty());
    config.set_project_folders({"/b", "/a", "/c"});
    CHECK(config.get_project_folders() == std::vector<std::string>{"/b", "/a", "/c"});
    config.set_project_folders({"/a"});
    CHECK(config.get_project_folders() == std::vector<std::string>{"/a"});
}
