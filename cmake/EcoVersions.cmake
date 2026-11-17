# Reads deps/versions.env, the one file eco's pinned versions are written in, into ECO_PIN_<KEY>
# variables (ECO_PIN_LLVM_COMMIT, ECO_PIN_MAX_VERSION, ECO_PIN_UV_VERSION, ...), and makes CMake
# reconfigure when it, or MAX's lock, changes. See scripts/deps.sh and plans/llvm-24-upgrade.md §1.
include_guard(GLOBAL)

set(_eco_versions_file "${CMAKE_SOURCE_DIR}/deps/versions.env")
if(NOT EXISTS "${_eco_versions_file}")
    message(FATAL_ERROR "deps/versions.env is missing: eco's pinned versions live there")
endif()
file(STRINGS "${_eco_versions_file}" _eco_version_lines REGEX "^[A-Z][A-Z0-9_]*=")
foreach(_line IN LISTS _eco_version_lines)
    string(REGEX MATCH "^([A-Z][A-Z0-9_]*)=(.*)$" _ "${_line}")
    string(STRIP "${CMAKE_MATCH_2}" _value)
    set(ECO_PIN_${CMAKE_MATCH_1} "${_value}")
endforeach()
foreach(_key LLVM_COMMIT LLVM_FOLLOWS MAX_VERSION UV_VERSION PYTHON_VERSION)
    if(NOT DEFINED ECO_PIN_${_key} OR ECO_PIN_${_key} STREQUAL "")
        message(FATAL_ERROR "deps/versions.env does not set ${_key}")
    endif()
endforeach()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${_eco_versions_file}" "${CMAKE_SOURCE_DIR}/deps/max/uv.lock")
