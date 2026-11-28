#pragma once

#include <cstddef>
#include <ctime>
#include <functional>
#include <string>
#include <vector>

#include <boost/filesystem/path.hpp>

namespace Slic3r {
// The project files listed under "All projects" on the home page: the 3MF projects in the folders the
// person chose, plus every project the slicers on this machine list as recently opened.
namespace ProjectLibrary {

// One slicer's recently opened projects, newest first.
struct RecentList
{
    std::string              app;   // the slicer's name as the person knows it ("Bambu Studio")
    std::vector<std::string> paths; // UTF-8, as the slicer saved them
};

struct Project
{
    std::string              path;              // UTF-8
    std::time_t              modified{0};
    std::vector<std::string> opened_in;         // the apps whose recent list names it, in RecentList order
    bool                     cloud_only{false}; // see is_cloud_only(): don't read it
};

struct ScanLimits
{
    int         max_depth{8};         // folder levels searched below each chosen folder
    std::size_t max_projects{2000};   // projects found in the folders before the search stops
    std::size_t max_entries{200000};  // directory entries visited, so a whole drive can't stall it
};

// A 3MF saved by a slicer as a project: Orca and its forks write Metadata/project_settings.config,
// PrusaSlicer and its forks Metadata/Slic3r_PE.config. A plain model 3MF has neither, and a sliced
// ".gcode.3mf" is a print file, not a project.
bool is_project_file(const boost::filesystem::path &file);

// True when the file's content lives only in the cloud (a OneDrive or other Files On-Demand
// placeholder on Windows), so reading it would download it. Always false on other systems.
bool is_cloud_only(const boost::filesystem::path &file);

// The projects in `recent` and under `folders`, each file once, newest first. A recent entry is taken
// as a project without opening it; a folder entry is opened to check (cloud-only files are kept
// unopened). Files that no longer exist are left out. Hidden folders ('.' or '$' prefix) are
// skipped. `stop` is polled while searching and ends the search early when it returns true.
std::vector<Project> collect(const std::vector<std::string> &folders,
                             const std::vector<RecentList>  &recent,
                             const ScanLimits               &limits = {},
                             const std::function<bool()>    &stop   = {});

} // namespace ProjectLibrary
} // namespace Slic3r
