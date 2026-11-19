# Run as Boost's PATCH_COMMAND from the source dir. Boost.Locale 1.84 passes
# include/boost/locale.hpp to source_group(TREE include/boost/locale), which only
# worked while CMake compared the paths as plain strings; CMake 4.5 compares path
# components and stops with "is not a prefix of file". locale.hpp gets its own
# source_group a line later, so leaving it out of the tree keeps the grouping.
set(_file "${CMAKE_CURRENT_SOURCE_DIR}/libs/locale/CMakeLists.txt")
file(READ "${_file}" _content)
set(_anchor "list(FILTER sources_inc EXCLUDE REGEX \"^src/\")")
set(_fix "list(FILTER sources_inc EXCLUDE REGEX \"boost/locale\\\\.hpp$\")")
string(FIND "${_content}" "${_fix}" _done)
if (_done EQUAL -1)
    string(FIND "${_content}" "${_anchor}" _at)
    if (_at EQUAL -1)
        message(FATAL_ERROR "Boost.Locale source_group fix: anchor not found in ${_file}")
    endif ()
    string(REPLACE "${_anchor}" "${_anchor}\n${_fix}" _content "${_content}")
    file(WRITE "${_file}" "${_content}")
endif ()
