cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
include(LLVMLibunwind)

# Runtime GC debug assertions: default ON for Debug builds, OFF for Release.
# Declared at top level so EVERY target that includes the allocator headers
# (NurserySpace, ThreadLocalHeap, Allocator) sees the same value of
# ECO_GC_DEBUG. The headers conditionally add a member (`in_minor_gc_`) under
# this macro, so any inconsistency causes an ODR/ABI mismatch between
# libraries and the test binary.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" ON)
else()
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" OFF)
endif()
if(ECO_GC_DEBUG)
    add_compile_definitions(ECO_GC_DEBUG=1)
endif()

# Validation-only switch for verifier passes (e.g. EcoBoxedStoreVerify,
# EcoPtrIntVerify, the GC liveness audit) AND extra runtime barriers in
# kernel/allocator copy loops that don't go through the hooked
# eco_store_field path. Independent of ECO_GC_DEBUG. Default OFF
# regardless of build type — slow.
option(ECO_LOWERING_VALIDATION
       "Enable validation-only verifier passes and runtime copy-loop barriers (slow)"
       OFF)
if(ECO_LOWERING_VALIDATION)
    add_compile_definitions(ECO_LOWERING_VALIDATION=1)
endif()

# Heap-validator switch. Independent of ECO_GC_DEBUG and
# ECO_LOWERING_VALIDATION. Enables the always-on stale-HPointer detection
# (write/read/arg-side hooks, free-region poisoning), the per-container
# bitmap-mismatch tripwires, the post-GC heap-integrity walker, the
# from-space pre-evacuation walk, the forward-chain-depth assert, and the
# old-gen / BBoP invariant audits. Off by default — these are hot-path
# checks. Turn on for diagnostic runs (heap-profile, stress).
option(ECO_HEAP_VALIDATE
       "Enable heap corruption detectors at every read/write/GC-walk site (slow)"
       OFF)
if(ECO_HEAP_VALIDATE)
    add_compile_definitions(ECO_HEAP_VALIDATE=1)
endif()

# Per-GC `[heap-trace] …` diagnostics. When OFF (default), the trace prints
# and their gathering logic are compiled out so they cost nothing on the hot
# path. When ON, the existing `ECO_HEAP_TRACE` env-var still gates emission at
# runtime — set `ECO_HEAP_TRACE=1` to actually see output.
option(ECO_HEAP_TRACE
       "Compile in per-GC [heap-trace] diagnostics (still gated by ECO_HEAP_TRACE env var)"
       OFF)
if(ECO_HEAP_TRACE)
    add_compile_definitions(ECO_HEAP_TRACE=1)
endif()

# Static-link switch (Stage A in plans/static-link-eco-binary.md). When ON,
# the eco binary is linked against static .a counterparts of curl/openssl/
# libzip/libunwind, plus -static-libstdc++ -static-libgcc. The resulting
# binary depends only on glibc and the dynamic linker. Default OFF — the
# everyday dev build stays dynamically linked. Stages B (MUSL Docker) and
# C (AOT-from-anywhere) build on this switch.
option(ECO_STATIC
       "Static-link curl/openssl/libzip/libunwind/libstdc++ into eco (glibc still shared)"
       OFF)

# Stage B (MUSL): the fully-static profile built inside the Alpine Docker
# image (docker/static-build.Dockerfile). Selects the libc++ / libc++abi /
# compiler-rt / LLVM-libunwind runtime stack and a `-static` (non-PIE) link,
# instead of Stage A's glibc + libstdc++ + libgcc profile. Implies ECO_STATIC.
# Set by the ninja-clang-lld-linux-musl preset. See
# plans/static-link-eco-binary.md (Stage B).
option(ECO_STATIC_MUSL
       "Stage B: fully-static MUSL build with libc++/compiler-rt (implies ECO_STATIC)"
       OFF)
if(ECO_STATIC_MUSL)
    set(ECO_STATIC ON CACHE BOOL "Static-link eco (forced on by ECO_STATIC_MUSL)" FORCE)
endif()

# Linker for the `eco` target. The Elm-compiled Stage-9 object carries
# R_X86_64_64 relocations in its .llvm_stackmaps section that lld rejects when
# producing a PIE, so the glibc builds force GNU ld (bfd). The Stage B MUSL
# build is non-PIE static, where lld accepts those relocs (verified — see the
# plan), so the musl preset flips this OFF. Kept as an explicit knob so a
# future lld regression can fall back to bfd (binutils is present in the
# Alpine image) without a code change.
option(ECO_LINK_WITH_BFD
       "Link the eco binary with GNU ld (bfd) instead of the preset's default linker"
       ON)

# Kernel-side stderr tracing for HTTP requests/responses, zip extraction, and
# file operations. Defined as ECO_KERNEL_DEBUG in the affected kernel libs
# (Http, File, NativeDriver, HttpService runtime). See the ECO_KLOG macro in
# eco-kernel-cpp/src/eco/KernelDebug.hpp.
option(ECO_KERNEL_DEBUG
       "Enable stderr tracing inside the HTTP / File / zip kernel paths"
       ON)

if(ECO_STATIC)
    # MUST be set BEFORE any add_subdirectory() that calls find_package on
    # these libs — otherwise the first subdir to call find_package(OpenSSL)
    # / find_package(CURL) / find_package(ZLIB) caches the .so path and
    # later subdirs silently inherit it. elm-kernel-cpp (line 92) is added
    # before eco-kernel-cpp (line 95) and was triggering exactly that.
    set(OPENSSL_USE_STATIC_LIBS TRUE)
    set(ZLIB_USE_STATIC_LIBS TRUE)
    # Prefer .a over .so for every find_library call. Scoped to the entire
    # build tree — under ECO_STATIC there's no case where we'd want a .so
    # fallback to silently win over an available .a.
    set(CMAKE_FIND_LIBRARY_SUFFIXES ".a;${CMAKE_FIND_LIBRARY_SUFFIXES}")

    # Vendor libcurl from source. Debian's libcurl.a was built with HTTP/2
    # + IDN + Brotli + ZSTD + LDAP + GSSAPI + SSH2 + RTMP enabled, but
    # Debian doesn't ship .a archives for any of those transitive deps —
    # linking the system libcurl.a fails with `cannot find -lnghttp2 /
    # -lidn2 / -lgssapi_krb5 / …`. Building a minimal libcurl (only the
    # OpenSSL TLS backend; HTTPS only) sidesteps the problem entirely.
    # Decision Q2 in plans/static-link-eco-binary.md.
    #
    # Vendored at the TOP level (not inside eco-kernel-cpp) so the
    # `libcurl_static` target exists before elm-kernel-cpp is added — both
    # subdirs link ElmKernel_Http / EcoKernel_Http against it.
    include(FetchContent)
    set(BUILD_CURL_EXE        OFF CACHE BOOL "" FORCE)
    set(BUILD_SHARED_LIBS     OFF CACHE BOOL "" FORCE)
    set(BUILD_STATIC_LIBS     ON  CACHE BOOL "" FORCE)
    set(BUILD_TESTING         OFF CACHE BOOL "" FORCE)
    set(BUILD_LIBCURL_DOCS    OFF CACHE BOOL "" FORCE)
    set(BUILD_MISC_DOCS       OFF CACHE BOOL "" FORCE)
    set(ENABLE_CURL_MANUAL    OFF CACHE BOOL "" FORCE)
    set(CURL_USE_OPENSSL      ON  CACHE BOOL "" FORCE)
    set(CURL_USE_LIBPSL       OFF CACHE BOOL "" FORCE)
    set(CURL_USE_LIBSSH2      OFF CACHE BOOL "" FORCE)
    set(CURL_USE_GSSAPI       OFF CACHE BOOL "" FORCE)
    set(USE_NGHTTP2           OFF CACHE BOOL "" FORCE)
    set(USE_LIBIDN2           OFF CACHE BOOL "" FORCE)
    set(USE_LIBRTMP           OFF CACHE BOOL "" FORCE)
    set(CURL_BROTLI           OFF CACHE BOOL "" FORCE)
    set(CURL_ZSTD             OFF CACHE BOOL "" FORCE)
    set(CURL_DISABLE_LDAP     ON  CACHE BOOL "" FORCE)
    set(CURL_DISABLE_LDAPS    ON  CACHE BOOL "" FORCE)
    # Disable protocols we don't use (compiler only fetches https://*).
    set(CURL_DISABLE_DICT     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_FILE     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_FTP      ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_GOPHER   ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_IMAP     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_MQTT     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_POP3     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_RTSP     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_SMB      ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_SMTP     ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_TELNET   ON CACHE BOOL "" FORCE)
    set(CURL_DISABLE_TFTP     ON CACHE BOOL "" FORCE)
    FetchContent_Declare(libcurl_vendored
        GIT_REPOSITORY https://github.com/curl/curl.git
        GIT_TAG curl-8_11_0
        GIT_SHALLOW TRUE
    )
    FetchContent_MakeAvailable(libcurl_vendored)
endif()

add_executable(ecor
        runtime/src/main.cpp
        runtime/src/allocator/RootSet.cpp
        runtime/src/allocator/HeapConfigJson.cpp
        runtime/src/allocator/OldGenSpace.cpp
        runtime/src/allocator/NurserySpace.cpp
        runtime/src/allocator/Allocator.cpp
        runtime/src/allocator/ThreadLocalHeap.cpp
        runtime/src/allocator/GCStats.cpp
        runtime/src/allocator/StackMap.cpp
        runtime/src/allocator/StackUnwind.cpp
        test/allocator/HeapGenerators.hpp
)

target_include_directories(ecor PRIVATE runtime/src/allocator)
target_compile_features(ecor PRIVATE cxx_std_20)

# Keep asserts enabled even in release builds for debugging
target_compile_options(ecor PRIVATE -UNDEBUG)

# Include debug symbols for stack traces (works with release optimization)
target_compile_options(ecor PRIVATE -g)

# Link RapidCheck
find_package(rapidcheck REQUIRED)
target_link_libraries(ecor PRIVATE rapidcheck)

# Add pthread for threading support
find_package(Threads REQUIRED)
target_link_libraries(ecor PRIVATE Threads::Threads)

# libunwind for stack unwinding in GC root scanning — specifically LLVM's
# libunwind (from LLVM_ENABLE_RUNTIMES); see cmake/LLVMLibunwind.cmake.
target_link_libraries(ecor PRIVATE eco::llvm_libunwind)

# Export symbols for stack traces (enables function names in backtrace)
target_link_options(ecor PRIVATE -rdynamic)

add_subdirectory(test)

# MLIR-based code generation
add_subdirectory(runtime/src/codegen)

# Elm kernel C++ implementation
add_subdirectory(elm-kernel-cpp)

# Eco kernel C++ implementation (IO operations)
add_subdirectory(eco-kernel-cpp)

# Guida compiler (Elm compiler written in Elm)
add_subdirectory(compiler)

# All Elm-tooling caches (eco-stuff/, elm-stuff/, bin/) now live under
# ${CMAKE_BINARY_DIR}/compiler/build-{xhr,kernel}/ and
# ${CMAKE_BINARY_DIR}/test/<pkg>/, shadowed in via the configure-time scaffolding
# in compiler/CMakeLists.txt and test/CMakeLists.txt. `rm -rf build/` resets
# everything; `ninja clean` removes ninja-tracked outputs but leaves the
# compiler's runtime caches alone — that's fine, the bootstrap chain and the
# Stage 5 stale-.ecot sweep handle staleness themselves.

# Convenience targets for common workflows.

# Usage: cmake --build build --target rebuild
add_custom_target(rebuild
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMENT "Clean, rebuild all targets"
    USES_TERMINAL
)

# Usage: cmake --build build --target check
# Usage with filter: TEST_FILTER=elm cmake --build build --target check
#
# Gate A in guides/bootstrap.md: build the default ALL graph (which
# includes Stage 1 / guida) and run the JIT E2E suite. The JIT runner
# compiles each Elm test through Stage 1's `compiler/bin/index.js`
# (guida.js via the XHR mock + eco-io-handler), so only Stage 1 is
# needed — no Stage 2+ build.
add_custom_target(check
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Gate A (incremental): build default ALL + Stage 1, run JIT E2E"
    USES_TERMINAL
)

# Usage: cmake --build build --target run-tests
# Usage with filter: TEST_FILTER=elm cmake --build build --target run-tests
add_custom_target(run-tests
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Run tests (no build)"
    USES_TERMINAL
)

# Usage: cmake --build build --target stress
# Usage with filter: TEST_FILTER=reverse cmake --build build --target stress
# Runs the separate stress-test binary (longer/larger Elm programs).
add_custom_target(stress
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target stress-test
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/stress-test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Build and run Elm stress tests"
    USES_TERMINAL
)

# Usage: cmake --build build --target full
# Usage with filter: TEST_FILTER=elm cmake --build build --target full
#
# Gate A in guides/bootstrap.md (from-clean): clean, rebuild the default
# ALL graph (which includes Stage 1 / guida), then run the JIT E2E suite.
# The JIT runner compiles each Elm test through Stage 1's
# `compiler/bin/index.js` (guida.js via the XHR mock + eco-io-handler),
# so only Stage 1 is needed — no Stage 2+ build.
add_custom_target(full
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Gate A: clean, rebuild default ALL + Stage 1, run JIT E2E"
    USES_TERMINAL
)
