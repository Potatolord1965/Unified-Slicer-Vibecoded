#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include "ProjectLibrary.hpp"

#include <algorithm>
#include <cstddef>
#include <ctime>
#include <functional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <boost/algorithm/string/case_conv.hpp>
#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem/directory.hpp>
#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/system/error_code.hpp>
#include <miniz.h>

#include "miniz_extension.hpp"

namespace Slic3r {
namespace ProjectLibrary {

namespace fs = boost::filesystem;

namespace {

bool has_project_extension(const fs::path &file)
{
    const std::string name = boost::algorithm::to_lower_copy(file.filename().string());
    return boost::algorithm::ends_with(name, ".3mf") && !boost::algorithm::ends_with(name, ".gcode.3mf");
}

// The same file however its path was spelled: separators, "." and "..", and the case on the
// case-insensitive file systems Windows and macOS use by default.
std::string identity(const fs::path &file)
{
    fs::path normal = file.lexically_normal();
    std::string key = normal.make_preferred().string();
#if defined(_WIN32) || defined(__APPLE__)
    boost::algorithm::to_lower(key);
#endif
    return key;
}

std::time_t modified_time(const fs::path &file)
{
    boost::system::error_code ec;
    const std::time_t t = fs::last_write_time(file, ec);
    return ec ? 0 : t;
}

} // namespace

bool is_project_file(const fs::path &file)
{
    if (!has_project_extension(file))
        return false;
    mz_zip_archive zip;
    mz_zip_zero_struct(&zip);
    if (!open_zip_reader(&zip, file.string()))
        return false;
    // Reads only the archive's central directory; entry names are matched case-insensitively.
    const bool project = mz_zip_reader_locate_file(&zip, "Metadata/project_settings.config", nullptr, 0) >= 0 ||
                         mz_zip_reader_locate_file(&zip, "Metadata/Slic3r_PE.config", nullptr, 0) >= 0;
    close_zip_reader(&zip);
    return project;
}

bool is_cloud_only(const fs::path &file)
{
#ifdef _WIN32
    // Older SDKs lack the Files On-Demand attributes.
    constexpr DWORD recall_on_open        = 0x00040000; // FILE_ATTRIBUTE_RECALL_ON_OPEN
    constexpr DWORD recall_on_data_access = 0x00400000; // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
    const DWORD attributes = ::GetFileAttributesW(file.wstring().c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & (FILE_ATTRIBUTE_OFFLINE | recall_on_open | recall_on_data_access)) != 0;
#else
    (void) file;
    return false;
#endif
}

std::vector<Project> collect(const std::vector<std::string> &folders,
                             const std::vector<RecentList>  &recent,
                             const ScanLimits               &limits,
                             const std::function<bool()>    &stop)
{
    std::vector<Project>                    out;
    std::unordered_map<std::string, size_t> index; // identity() -> position in `out`
    auto stopped = [&stop]() { return stop && stop(); };

    for (const RecentList &list : recent) {
        for (const std::string &path : list.paths) {
            const fs::path file(path);
            boost::system::error_code ec;
            if (!has_project_extension(file) || !fs::is_regular_file(file, ec))
                continue;
            const auto [it, added] = index.emplace(identity(file), out.size());
            if (added) {
                Project project;
                project.path       = path;
                project.modified   = modified_time(file);
                project.cloud_only = is_cloud_only(file);
                out.push_back(std::move(project));
            }
            std::vector<std::string> &apps = out[it->second].opened_in;
            if (std::find(apps.begin(), apps.end(), list.app) == apps.end())
                apps.push_back(list.app);
        }
    }

    size_t found = 0, visited = 0;
    for (const std::string &folder : folders) {
        boost::system::error_code ec;
        fs::recursive_directory_iterator it(fs::path(folder), fs::directory_options::skip_permission_denied, ec), end;
        for (; !ec && it != end; it.increment(ec)) {
            if (++visited > limits.max_entries || found >= limits.max_projects || stopped())
                break;
            const fs::path    &path = it->path();
            const std::string  name = path.filename().string();
            boost::system::error_code status_ec;
            const fs::file_status status = it->status(status_ec);
            if (status_ec)
                continue;
            if (fs::is_directory(status)) {
                if (name.empty() || name.front() == '.' || name.front() == '$' || it.depth() + 1 >= limits.max_depth)
                    it.disable_recursion_pending();
                continue;
            }
            if (!fs::is_regular_file(status) || !has_project_extension(path))
                continue;
            const std::string key = identity(path);
            if (index.count(key) != 0)
                continue;
            // A cloud-only file can't be checked without downloading it; in a projects folder it most
            // likely is one.
            const bool cloud_only = is_cloud_only(path);
            if (!cloud_only && !is_project_file(path))
                continue;
            index.emplace(key, out.size());
            Project project;
            project.path       = path.string();
            project.modified   = modified_time(path);
            project.cloud_only = cloud_only;
            out.push_back(std::move(project));
            ++found;
        }
    }

    std::stable_sort(out.begin(), out.end(), [](const Project &a, const Project &b) { return a.modified > b.modified; });
    return out;
}

} // namespace ProjectLibrary
} // namespace Slic3r
