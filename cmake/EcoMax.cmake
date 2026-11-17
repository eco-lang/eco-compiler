# Modular MAX as a build dependency (plans/llvm-24-upgrade.md §5).
#
# ECO_MAX selects it:
#   AUTO (default)  on where MAX publishes wheels (Linux glibc x86_64/aarch64, macOS arm64) and uv is
#                   installed; otherwise off, saying why
#   ON              required: configure fails if MAX cannot be installed (CI's test jobs use this)
#   OFF             not used (release bundles: eco never ships MAX)
#
# When on, configure installs the pinned MAX (deps/max/, locked by uv.lock) with uv into
# ${ECO_MAX_ENV} (default build/toolchain/max-env), re-syncing whenever the lock changes, and sets:
#   ECO_MAX_ENABLED       TRUE
#   ECO_MAX_PACKAGE_ROOT  the wheel's `modular` directory (lib/libmax.*, lib/mojo)
#   ECO_MAX_INCLUDE_DIR   MAX's C API headers (max/c/*.h)
# eco loads libmax at run time (runtime/src/max/MaxLoader.hpp); nothing links it.
include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/EcoVersions.cmake")

set(ECO_MAX "AUTO" CACHE STRING "Use Modular MAX: AUTO (where available), ON (required) or OFF")
set_property(CACHE ECO_MAX PROPERTY STRINGS AUTO ON OFF)
set(ECO_MAX_ENV "${CMAKE_BINARY_DIR}/toolchain/max-env" CACHE PATH
    "Where configure installs the pinned MAX (a uv-managed Python environment)")

set(ECO_MAX_ENABLED FALSE)
set(ECO_MAX_PACKAGE_ROOT "")
set(ECO_MAX_INCLUDE_DIR "")

# Says why MAX is off: fatal when it was required, a status line otherwise.
macro(_eco_max_off why)
    if(ECO_MAX STREQUAL "ON")
        message(FATAL_ERROR "ECO_MAX=ON, but ${why}")
    endif()
    message(STATUS "MAX: off (${why})")
    return()
endmacro()

if(ECO_MAX STREQUAL "OFF")
    message(STATUS "MAX: off (ECO_MAX=OFF)")
    return()
endif()
if(NOT ECO_MAX MATCHES "^(AUTO|ON)$")
    message(FATAL_ERROR "ECO_MAX must be AUTO, ON or OFF, not '${ECO_MAX}'")
endif()

# MAX publishes manylinux_2_34 x86_64/aarch64 and macOS arm64 wheels only.
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _eco_max_cpu)
if(ECO_STATIC_MUSL OR ECO_GLIBC_OUTPUT_RUNTIME)
    _eco_max_off("MAX has no musl build, and this is a static musl or archive-only configuration")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND _eco_max_cpu MATCHES "^(x86_64|amd64|aarch64|arm64)$")
elseif(APPLE AND (_eco_max_cpu STREQUAL "arm64" OR CMAKE_OSX_ARCHITECTURES STREQUAL "arm64"))
else()
    _eco_max_off("MAX publishes no build for ${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
endif()

find_program(ECO_UV_EXECUTABLE uv)
if(NOT ECO_UV_EXECUTABLE)
    _eco_max_off("uv is not installed (uv ${ECO_PIN_UV_VERSION} installs the pinned MAX; https://docs.astral.sh/uv/)")
endif()
execute_process(COMMAND "${ECO_UV_EXECUTABLE}" --version OUTPUT_VARIABLE _eco_uv_out
                OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _eco_uv_rc)
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" _eco_uv_version "${_eco_uv_out}")
if(NOT _eco_uv_rc EQUAL 0 OR _eco_uv_version VERSION_LESS ECO_PIN_UV_VERSION)
    _eco_max_off("${ECO_UV_EXECUTABLE} is uv '${_eco_uv_version}', older than the pinned ${ECO_PIN_UV_VERSION}")
endif()

# Sync the environment when the lock, the project or the Python pin changed since the last sync.
file(SHA256 "${CMAKE_SOURCE_DIR}/deps/max/uv.lock" _eco_max_lock_hash)
file(SHA256 "${CMAKE_SOURCE_DIR}/deps/max/pyproject.toml" _eco_max_project_hash)
set(_eco_max_stamp_want "${_eco_max_lock_hash} ${_eco_max_project_hash} ${ECO_PIN_PYTHON_VERSION}")
set(_eco_max_stamp "${ECO_MAX_ENV}.synced")
set(_eco_max_stamp_have "")
if(EXISTS "${_eco_max_stamp}")
    file(READ "${_eco_max_stamp}" _eco_max_stamp_have)
endif()
if(NOT _eco_max_stamp_have STREQUAL _eco_max_stamp_want OR NOT EXISTS "${ECO_MAX_ENV}")
    message(STATUS "MAX: installing max ${ECO_PIN_MAX_VERSION} with uv into ${ECO_MAX_ENV}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E env "UV_PROJECT_ENVIRONMENT=${ECO_MAX_ENV}"
                "${ECO_UV_EXECUTABLE}" sync --frozen --quiet
                --project "${CMAKE_SOURCE_DIR}/deps/max" --python "${ECO_PIN_PYTHON_VERSION}"
        RESULT_VARIABLE _eco_max_sync_rc
        ERROR_VARIABLE _eco_max_sync_err)
    if(NOT _eco_max_sync_rc EQUAL 0)
        file(REMOVE "${_eco_max_stamp}")
        _eco_max_off("installing the pinned MAX failed (uv sync): ${_eco_max_sync_err}")
    endif()
    file(WRITE "${_eco_max_stamp}" "${_eco_max_stamp_want}")
endif()

file(GLOB _eco_max_sites LIST_DIRECTORIES TRUE "${ECO_MAX_ENV}/lib/python*/site-packages")
list(LENGTH _eco_max_sites _eco_max_site_count)
if(NOT _eco_max_site_count EQUAL 1)
    _eco_max_off("${ECO_MAX_ENV} does not hold exactly one site-packages")
endif()
if(APPLE)
    set(_eco_max_lib "libmax.dylib")
else()
    set(_eco_max_lib "libmax.so")
endif()
set(ECO_MAX_PACKAGE_ROOT "${_eco_max_sites}/modular")
set(ECO_MAX_INCLUDE_DIR "${_eco_max_sites}/max/include")
if(NOT EXISTS "${ECO_MAX_PACKAGE_ROOT}/lib/${_eco_max_lib}" OR NOT EXISTS "${ECO_MAX_INCLUDE_DIR}/max/c/model.h")
    _eco_max_off("the installed max wheel lacks lib/${_eco_max_lib} or its C headers (its layout changed?)")
endif()
set(ECO_MAX_ENABLED TRUE)
message(STATUS "MAX: ${ECO_PIN_MAX_VERSION} at ${ECO_MAX_PACKAGE_ROOT}")
