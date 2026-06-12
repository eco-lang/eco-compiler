# Fetch and pin the Elm toolchain binaries (elm, elm-format, elm-test-rs)
# directly from their upstream GitHub releases.
#
# Why this exists: the npm packages of the same names use binwrap install
# scripts that fetch the binary at `npm install` time from a third-party
# host. Pinning the npm package-lock.json only pins the wrapper, not the
# binary that lands in node_modules/.bin/. By moving the fetch into CMake
# with SHA256-pinned URLs we remove four arbitrary-code-execution surfaces
# from the build and let pnpm run with ignore-scripts=true (see
# compiler/.npmrc).
#
# Linux x86_64 only — see compiler/CMakeLists.txt for the platform gate.

set(TOOLCHAIN_DIR "${CMAKE_BINARY_DIR}/toolchain")
set(TOOLCHAIN_BIN "${TOOLCHAIN_DIR}/bin")
set(TOOLCHAIN_CACHE "${TOOLCHAIN_DIR}/cache")
file(MAKE_DIRECTORY ${TOOLCHAIN_BIN} ${TOOLCHAIN_CACHE})

# ---------------------------------------------------------------------------
# Robust download helper.
#
# GitHub release fetches are intermittently slow or rate-limited. A bare
# `file(DOWNLOAD ... EXPECTED_HASH ...)` has no timeout and no retry, so a
# single stalled connection aborts the whole configure with the misleading
#   "file DOWNLOAD cannot compute hash on failed download
#    status: [28;"Timeout was reached"]"
# (on a failed/partial transfer EXPECTED_HASH still tries to hash the empty
# file, producing that message).
#
# eco_fetch() instead bounds each attempt with TIMEOUT + INACTIVITY_TIMEOUT,
# captures STATUS so a failure does NOT abort the configure, retries with a
# small backoff, and verifies the SHA256 ITSELF after a clean transfer (a
# truncated download that still reports status 0 is caught as a hash mismatch
# and retried). Only once every attempt is exhausted does it FATAL_ERROR.
# Tunable from the command line via the cache variables below.
# ---------------------------------------------------------------------------
set(ECO_FETCH_RETRIES            3   CACHE STRING "Toolchain download attempts before giving up")
set(ECO_FETCH_TIMEOUT            600 CACHE STRING "Per-attempt total transfer timeout (seconds)")
set(ECO_FETCH_INACTIVITY_TIMEOUT 60  CACHE STRING "Per-attempt no-data-received timeout (seconds)")

function(eco_fetch _name _url _expected_sha _out)
    string(TOLOWER "${_expected_sha}" _want)
    foreach(_attempt RANGE 1 ${ECO_FETCH_RETRIES})
        message(STATUS "Fetching ${_name} (attempt ${_attempt}/${ECO_FETCH_RETRIES})")
        file(DOWNLOAD "${_url}" "${_out}"
            STATUS _status
            TIMEOUT ${ECO_FETCH_TIMEOUT}
            INACTIVITY_TIMEOUT ${ECO_FETCH_INACTIVITY_TIMEOUT}
            SHOW_PROGRESS)
        list(GET _status 0 _code)
        list(GET _status 1 _msg)
        if(_code EQUAL 0)
            file(SHA256 "${_out}" _got)
            string(TOLOWER "${_got}" _got)
            if(_got STREQUAL _want)
                message(STATUS "Fetched ${_name}: SHA256 verified")
                return()
            endif()
            message(WARNING
                "${_name}: SHA256 mismatch (download truncated or upstream changed)\n"
                "  expected ${_want}\n"
                "  actual   ${_got}")
        else()
            message(WARNING "${_name}: download failed (status ${_code}: ${_msg})")
        endif()
        file(REMOVE "${_out}")
        if(_attempt LESS ${ECO_FETCH_RETRIES})
            execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
        endif()
    endforeach()
    message(FATAL_ERROR
        "Failed to fetch ${_name} from ${_url} after ${ECO_FETCH_RETRIES} attempt(s). "
        "This is usually a transient network/GitHub issue — re-run the configure, or "
        "raise -DECO_FETCH_RETRIES / -DECO_FETCH_TIMEOUT.")
endfunction()

# --- elm 0.19.1 -------------------------------------------------------------
set(ELM_URL  "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz")
set(ELM_SHA  "e44af52bb27f725a973478e589d990a6428e115fe1bb14f03833134d6c0f155c")
set(ELM_GZ   "${TOOLCHAIN_CACHE}/elm-0.19.1.gz")
set(ELM_BIN  "${TOOLCHAIN_BIN}/elm")

if(NOT EXISTS "${ELM_BIN}")
    eco_fetch("elm 0.19.1" "${ELM_URL}" "${ELM_SHA}" "${ELM_GZ}")
    execute_process(
        COMMAND sh -c "gunzip -c '${ELM_GZ}' > '${ELM_BIN}'"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "Failed to gunzip elm binary (rc=${_rc})")
    endif()
    execute_process(COMMAND chmod +x "${ELM_BIN}")
endif()

# --- elm-format 0.8.7 -------------------------------------------------------
set(ELM_FORMAT_URL "https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-linux-x64.tgz")
set(ELM_FORMAT_SHA "44344c7b6f838dc5d9495dfe4253280a698c2251ee8cfa29b6d1a032b6efb13b")
set(ELM_FORMAT_TGZ "${TOOLCHAIN_CACHE}/elm-format-0.8.7.tgz")
set(ELM_FORMAT_BIN "${TOOLCHAIN_BIN}/elm-format")

if(NOT EXISTS "${ELM_FORMAT_BIN}")
    eco_fetch("elm-format 0.8.7" "${ELM_FORMAT_URL}" "${ELM_FORMAT_SHA}" "${ELM_FORMAT_TGZ}")
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xzf "${ELM_FORMAT_TGZ}"
        WORKING_DIRECTORY "${TOOLCHAIN_BIN}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "Failed to extract elm-format (rc=${_rc})")
    endif()
endif()

# --- elm-test-rs 3.0.1 ------------------------------------------------------
set(ELM_TEST_RS_URL "https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_linux.tar.gz")
set(ELM_TEST_RS_SHA "3d99e394f2a90ddf5fcb579b7c9c822b62c2a71c5621cb9e2c5d5b37f8a9d5a7")
set(ELM_TEST_RS_TGZ "${TOOLCHAIN_CACHE}/elm-test-rs-3.0.1.tgz")
set(ELM_TEST_RS_BIN "${TOOLCHAIN_BIN}/elm-test-rs")

if(NOT EXISTS "${ELM_TEST_RS_BIN}")
    eco_fetch("elm-test-rs 3.0.1" "${ELM_TEST_RS_URL}" "${ELM_TEST_RS_SHA}" "${ELM_TEST_RS_TGZ}")
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xzf "${ELM_TEST_RS_TGZ}"
        WORKING_DIRECTORY "${TOOLCHAIN_BIN}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "Failed to extract elm-test-rs (rc=${_rc})")
    endif()
endif()

# Expose binaries as cache variables so they survive reconfigure and can be
# overridden from the command line if needed.
set(ELM_EXECUTABLE         "${ELM_BIN}"         CACHE FILEPATH "Path to the elm 0.19.1 binary")
set(ELM_FORMAT_EXECUTABLE  "${ELM_FORMAT_BIN}"  CACHE FILEPATH "Path to the elm-format binary")
set(ELM_TEST_RS_EXECUTABLE "${ELM_TEST_RS_BIN}" CACHE FILEPATH "Path to the elm-test-rs binary")

message(STATUS "Toolchain: elm         = ${ELM_EXECUTABLE}")
message(STATUS "Toolchain: elm-format  = ${ELM_FORMAT_EXECUTABLE}")
message(STATUS "Toolchain: elm-test-rs = ${ELM_TEST_RS_EXECUTABLE}")
