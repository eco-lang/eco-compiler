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

# --- elm 0.19.1 -------------------------------------------------------------
set(ELM_URL  "https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz")
set(ELM_SHA  "e44af52bb27f725a973478e589d990a6428e115fe1bb14f03833134d6c0f155c")
set(ELM_GZ   "${TOOLCHAIN_CACHE}/elm-0.19.1.gz")
set(ELM_BIN  "${TOOLCHAIN_BIN}/elm")

if(NOT EXISTS "${ELM_BIN}")
    message(STATUS "Fetching elm 0.19.1 binary")
    file(DOWNLOAD "${ELM_URL}" "${ELM_GZ}"
        EXPECTED_HASH SHA256=${ELM_SHA}
        SHOW_PROGRESS)
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
    message(STATUS "Fetching elm-format 0.8.7")
    file(DOWNLOAD "${ELM_FORMAT_URL}" "${ELM_FORMAT_TGZ}"
        EXPECTED_HASH SHA256=${ELM_FORMAT_SHA}
        SHOW_PROGRESS)
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
    message(STATUS "Fetching elm-test-rs 3.0.1")
    file(DOWNLOAD "${ELM_TEST_RS_URL}" "${ELM_TEST_RS_TGZ}"
        EXPECTED_HASH SHA256=${ELM_TEST_RS_SHA}
        SHOW_PROGRESS)
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
