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
# Platforms: Linux x86_64, macOS (arm64 / x86_64), Windows x86_64 — see the
# per-platform URL/SHA table below and the platform gate in
# compiler/CMakeLists.txt.

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

# ---------------------------------------------------------------------------
# Per-platform release assets. All three tools ship upstream prebuilts for
# every platform below. SHA256s were computed from the upstream downloads on
# 2026-06-12 (Linux SHAs unchanged from the original pinning).
# ---------------------------------------------------------------------------
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    set(ELM_URL "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz")
    set(ELM_SHA "e44af52bb27f725a973478e589d990a6428e115fe1bb14f03833134d6c0f155c")
    set(ELM_FORMAT_URL "https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-linux-x64.tgz")
    set(ELM_FORMAT_SHA "44344c7b6f838dc5d9495dfe4253280a698c2251ee8cfa29b6d1a032b6efb13b")
    set(ELM_TEST_RS_URL "https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_linux.tar.gz")
    set(ELM_TEST_RS_SHA "3d99e394f2a90ddf5fcb579b7c9c822b62c2a71c5621cb9e2c5d5b37f8a9d5a7")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
    set(ELM_URL "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-mac-64-bit-ARM.gz")
    set(ELM_SHA "552c8300b55dafdf52073b095e7bc6afc1b2ea2a600fbc7654bca8a241e38689")
    set(ELM_FORMAT_URL "https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-mac-arm64.tgz")
    set(ELM_FORMAT_SHA "d8f898be599fa767d3b6607256e273dd4f62ea7abc41369a068e903159787098")
    set(ELM_TEST_RS_URL "https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_macos-arm.tar.gz")
    set(ELM_TEST_RS_SHA "e2be5e6d2c1b9e18729a330b9b7db7a286c9f9f34376b634b910e52378219df5")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    set(ELM_URL "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-mac-64-bit.gz")
    set(ELM_SHA "05289f0e3d4f30033487c05e689964c3bb17c0c48012510dbef1df43868545d1")
    set(ELM_FORMAT_URL "https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-mac-x64.tgz")
    set(ELM_FORMAT_SHA "064102cd471550beb43ff7eb3dd6ac7c2a1946cf038dbde389873384f62cbdc4")
    set(ELM_TEST_RS_URL "https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_macos.tar.gz")
    set(ELM_TEST_RS_SHA "614936b1f3b2d5488c4168399446821c9304c2c2c1f4701f23e65199e3a8e6ba")
elseif(WIN32 AND (CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64"))
    set(ELM_URL "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-windows-64-bit.gz")
    set(ELM_SHA "d1bf666298cbe3c5447b9ca0ea608552d750e5d232f9845c2af11907b654903b")
    set(ELM_FORMAT_URL "https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-win-x64.zip")
    set(ELM_FORMAT_SHA "24833297bc58f6e72708b0f95a03c73190aa22d5e789b89ba1c00796a58abf7f")
    # Upstream packaging quirk: `elm-test-rs_windows.zip` is actually a
    # gzipped tar — `file(1)` reports "gzip compressed data" — containing a
    # single `elm-test-rs.exe`. The extraction path below uses tar regardless
    # of suffix, so this Just Works.
    set(ELM_TEST_RS_URL "https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_windows.zip")
    set(ELM_TEST_RS_SHA "8d375c48eac4451d930e0d64678d7f9e018093d704d2f436052984809dfe9a0d")
else()
    message(FATAL_ERROR
        "No pinned Elm toolchain binaries for "
        "${CMAKE_SYSTEM_NAME}/${CMAKE_SYSTEM_PROCESSOR}. "
        "Add a URL/SHA row to compiler/cmake/toolchain.cmake.")
endif()

# Per-platform: binary suffix and a gunzip helper. On POSIX we shell out to
# gunzip; on Windows there is no POSIX shell guaranteed (Git Bash may be
# absent in a fresh VS Build Tools install), so we use PowerShell's
# System.IO.Compression.GZipStream — a stdlib path with no extra deps.
if(WIN32)
    set(ECO_EXE_SUFFIX ".exe")
    function(_eco_gunzip _src _dst)
        execute_process(
            COMMAND powershell -NoProfile -ExecutionPolicy Bypass -Command
                "$in = [System.IO.File]::OpenRead('${_src}'); \
                 $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress); \
                 $out = [System.IO.File]::Create('${_dst}'); \
                 $gz.CopyTo($out); $out.Close(); $gz.Close(); $in.Close()"
            RESULT_VARIABLE _rc)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "PowerShell GZipStream decompress failed (rc=${_rc}): ${_src} → ${_dst}")
        endif()
    endfunction()
else()
    set(ECO_EXE_SUFFIX "")
    function(_eco_gunzip _src _dst)
        execute_process(
            COMMAND sh -c "gunzip -c '${_src}' > '${_dst}'"
            RESULT_VARIABLE _rc)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "gunzip failed (rc=${_rc}): ${_src} → ${_dst}")
        endif()
        execute_process(COMMAND chmod +x "${_dst}")
    endfunction()
endif()

# --- elm 0.19.1 -------------------------------------------------------------
set(ELM_GZ   "${TOOLCHAIN_CACHE}/elm-0.19.1.gz")
set(ELM_BIN  "${TOOLCHAIN_BIN}/elm${ECO_EXE_SUFFIX}")

if(NOT EXISTS "${ELM_BIN}")
    eco_fetch("elm 0.19.1" "${ELM_URL}" "${ELM_SHA}" "${ELM_GZ}")
    _eco_gunzip("${ELM_GZ}" "${ELM_BIN}")
endif()

# --- elm-format 0.8.7 -------------------------------------------------------
# Linux/macOS upstream is .tgz; Windows upstream is .zip. CMake's
# file(ARCHIVE_EXTRACT) handles both, but `cmake -E tar xzf` does NOT handle
# zip — use the archive helper and let it sniff the format.
if(WIN32)
    set(ELM_FORMAT_ARCHIVE "${TOOLCHAIN_CACHE}/elm-format-0.8.7.zip")
else()
    set(ELM_FORMAT_ARCHIVE "${TOOLCHAIN_CACHE}/elm-format-0.8.7.tgz")
endif()
set(ELM_FORMAT_BIN "${TOOLCHAIN_BIN}/elm-format${ECO_EXE_SUFFIX}")

if(NOT EXISTS "${ELM_FORMAT_BIN}")
    eco_fetch("elm-format 0.8.7" "${ELM_FORMAT_URL}" "${ELM_FORMAT_SHA}" "${ELM_FORMAT_ARCHIVE}")
    file(ARCHIVE_EXTRACT
        INPUT       "${ELM_FORMAT_ARCHIVE}"
        DESTINATION "${TOOLCHAIN_BIN}")
endif()

# --- elm-test-rs 3.0.1 ------------------------------------------------------
# Linux/macOS upstream is .tar.gz; Windows upstream is also .tar.gz but
# misnamed with a .zip suffix (see the URL/SHA block above). Always treat
# as tar (file(ARCHIVE_EXTRACT) sniffs the format).
set(ELM_TEST_RS_ARCHIVE "${TOOLCHAIN_CACHE}/elm-test-rs-3.0.1.tgz")
set(ELM_TEST_RS_BIN "${TOOLCHAIN_BIN}/elm-test-rs${ECO_EXE_SUFFIX}")

if(NOT EXISTS "${ELM_TEST_RS_BIN}")
    eco_fetch("elm-test-rs 3.0.1" "${ELM_TEST_RS_URL}" "${ELM_TEST_RS_SHA}" "${ELM_TEST_RS_ARCHIVE}")
    file(ARCHIVE_EXTRACT
        INPUT       "${ELM_TEST_RS_ARCHIVE}"
        DESTINATION "${TOOLCHAIN_BIN}")
endif()

# Expose binaries as cache variables so they survive reconfigure and can be
# overridden from the command line if needed.
set(ELM_EXECUTABLE         "${ELM_BIN}"         CACHE FILEPATH "Path to the elm 0.19.1 binary")
set(ELM_FORMAT_EXECUTABLE  "${ELM_FORMAT_BIN}"  CACHE FILEPATH "Path to the elm-format binary")
set(ELM_TEST_RS_EXECUTABLE "${ELM_TEST_RS_BIN}" CACHE FILEPATH "Path to the elm-test-rs binary")

message(STATUS "Toolchain: elm         = ${ELM_EXECUTABLE}")
message(STATUS "Toolchain: elm-format  = ${ELM_FORMAT_EXECUTABLE}")
message(STATUS "Toolchain: elm-test-rs = ${ELM_TEST_RS_EXECUTABLE}")
