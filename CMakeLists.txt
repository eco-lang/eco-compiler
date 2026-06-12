cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES C CXX)

# All project archives are built position-independent so eco can link them
# into shared-library outputs (.so/.node host embedding) as well as PIE
# executables. See plans/native-ports-and-embedding.md (Phase 3).
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

# Front-end-only configure: just the compiler/ subdirectory (bootstrap
# stages 1–5, which are pure Node/Elm — no LLVM, MLIR, libunwind, kernels,
# runtime, or tests). Used for porting work (plans/build-on-mac.md) and any
# environment that wants the Elm front-end without the native toolchain.
option(ECO_FRONTEND_ONLY
       "Configure only the Elm front-end bootstrap (stages 1-5); skip the native backend, runtime, kernels and tests"
       OFF)

if(NOT ECO_FRONTEND_ONLY)
    include(LLVMLibunwind)
endif()

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

# GC allocation/timing counters + the exit-time `=== GC Statistics ===`
# banner. Default ON for any non-Release build (so the dev `build/` and
# `debug/` presets keep the stats path live), OFF under Release so user-
# facing AOT binaries built from the static musl preset don't drag the
# counter overhead or clutter stderr at exit.
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    option(ECO_GC_STATS "Enable GC allocation/timing counters and the exit-time stats banner" OFF)
else()
    option(ECO_GC_STATS "Enable GC allocation/timing counters and the exit-time stats banner" ON)
endif()
if(ECO_GC_STATS)
    add_compile_definitions(ENABLE_GC_STATS=1)
else()
    add_compile_definitions(ENABLE_GC_STATS=0)
endif()

# Force `assert(...)` to compile through, even in release builds. The runtime
# allocator and the kernel libraries have hundreds of asserts on the hot
# path that catch real bugs during bootstrap self-compile. Default ON for
# any non-Release build; OFF for Release so shipped binaries don't pay the
# runtime cost. The actual `-UNDEBUG` flag is applied via target_compile_options
# in the individual runtime/kernel CMakeLists when this is ON.
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    option(ECO_ASSERTS_ON "Force `assert(...)` to remain enabled (re-applies -UNDEBUG)" OFF)
else()
    option(ECO_ASSERTS_ON "Force `assert(...)` to remain enabled (re-applies -UNDEBUG)" ON)
endif()

# Convenience knobs surfaced as options instead of preset variants. The
# old `ninja-clang-lld-linux-ccache` / `-profile` presets are gone — set
# these when configuring whichever main preset you want.
option(ECO_USE_CCACHE "Wrap C/C++ compiles with ccache" OFF)
if(ECO_USE_CCACHE)
    find_program(CCACHE_EXECUTABLE ccache REQUIRED)
    set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_EXECUTABLE}" CACHE STRING "" FORCE)
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_EXECUTABLE}" CACHE STRING "" FORCE)
endif()

option(ECO_FRAME_POINTERS "Compile with frame pointers preserved (for perf / flamegraph)" OFF)
if(ECO_FRAME_POINTERS)
    add_compile_options(-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer)
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

# Stage D: archive-only configure mode for the glibc OUTPUT runtime — the
# second set of link inputs the musl bundle ships under
# lib/eco-runtime/glibc/ so the static `eco` can produce glibc-ABI
# .so/.node outputs. Run on a glibc host (docker/static-build.Dockerfile's
# `glibc-runtime` stage, FROM eco-llvm-debian); gates off compiler/, test/
# and ecor below (the Debian LLVM image carries no node/pnpm/rapidcheck).
# Requires ECO_STATIC=ON for the vendored curl/zip archive targets.
# See plans/stage-d-hybrid-link-profiles.md (step 2).
option(ECO_GLIBC_OUTPUT_RUNTIME
       "Stage D: build only the glibc-ABI output-runtime archive set (no compiler, no tests)"
       OFF)
if(ECO_GLIBC_OUTPUT_RUNTIME AND ECO_STATIC_MUSL)
    message(FATAL_ERROR "ECO_GLIBC_OUTPUT_RUNTIME is a glibc-host build mode; "
        "it cannot be combined with ECO_STATIC_MUSL")
endif()
if(ECO_GLIBC_OUTPUT_RUNTIME AND NOT ECO_STATIC)
    message(FATAL_ERROR "ECO_GLIBC_OUTPUT_RUNTIME requires ECO_STATIC=ON "
        "(the vendored libcurl/libzip archive targets only exist under it)")
endif()
if(ECO_GLIBC_OUTPUT_RUNTIME)
    # Compile the staged archives against libc++ so they match the libc++.a /
    # libc++abi.a the Stage D recipe links — symmetric with the musl side,
    # whose `release` preset sets -stdlib=libc++ globally. The `build` preset
    # this mode runs under does NOT, so on Debian clang the kernels would
    # otherwise compile against GCC libstdc++ (std::__cxx11) and the produced
    # .so/.node would fail to dlopen on the libc++ (std::__1) symbols it links
    # against. CXX-only so the handful of C kernel files don't warn. libc++
    # headers come from the apt libc++-N-dev the glibc-runtime stage installs.
    add_compile_options($<$<COMPILE_LANGUAGE:CXX>:-stdlib=libc++>)
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
# eco-kernel-cpp/src/eco/KernelDebug.hpp. Default OFF — the `dev` preset
# flips it back ON for diagnostic builds; the `build` and `release` presets
# inherit OFF so user-visible binaries stay quiet on stderr.
option(ECO_KERNEL_DEBUG
       "Enable stderr tracing inside the HTTP / File / zip kernel paths"
       OFF)

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

    # Stage D: vendor zlib too — but ONLY for the glibc-output-runtime
    # archive build. Debian's libz.a is not PIC (a -shared trial link fails
    # with `relocation R_X86_64_PC32 cannot be used against symbol
    # 'z_errmsg'`), and zlib members land in every produced .so/.node
    # (vendored curl uses gzip Content-Encoding; libzip requires z). The
    # Alpine/musl path keeps using apk's zlib-static — its outputs are
    # non-PIE static executables where PIC never matters. Tag pinned to
    # bookworm's zlib (1.2.13) so the archive matches the headers curl/zip
    # compile against. PIC comes from the global
    # CMAKE_POSITION_INDEPENDENT_CODE ON (line 7).
    # See plans/stage-d-hybrid-link-profiles.md (step 2).
    if(ECO_GLIBC_OUTPUT_RUNTIME)
        FetchContent_Declare(zlib_vendored
            GIT_REPOSITORY https://github.com/madler/zlib.git
            GIT_TAG v1.2.13
            GIT_SHALLOW TRUE
        )
        FetchContent_MakeAvailable(zlib_vendored)
        if(NOT TARGET zlibstatic)
            message(FATAL_ERROR "Stage D: vendored zlib did not produce the 'zlibstatic' target")
        endif()
    endif()
endif()

# Stage D archive-only mode: ecor (needs rapidcheck), the test tree and the
# compiler (hard-requires node + pnpm at configure time,
# compiler/CMakeLists.txt) are all gated off — the Debian glibc-runtime
# builder image provides none of those, and the mode only exists to build
# the archive set staged by eco-glibc-runtime-tree below.
if(NOT ECO_GLIBC_OUTPUT_RUNTIME AND NOT ECO_FRONTEND_ONLY)

add_executable(ecor EXCLUDE_FROM_ALL
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

# Asserts on iff ECO_ASSERTS_ON (default ON for non-Release builds).
if(ECO_ASSERTS_ON)
    target_compile_options(ecor PRIVATE -UNDEBUG)
endif()

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
if(APPLE)
    # ENABLE_EXPORTS is CMake's portable spelling of -rdynamic (ld64 takes
    # -export_dynamic; the property picks the right flag per platform).
    set_target_properties(ecor PROPERTIES ENABLE_EXPORTS ON)
else()
    target_link_options(ecor PRIVATE -rdynamic)
endif()

# EXCLUDE_FROM_ALL: test binaries (test, stress-test, mlir-equivalence,
# aot-e2e-runner) are dev-time tools, not distribution artifacts. Build them on
# demand via the convenience targets (`check`, `full`, `stress`,
# `run-mlir-equivalence`, `run-aot-e2e`) — which depend on them explicitly and
# work as advertised — or via `cmake --build build --target <bin>` directly.
# Keeps them out of the default `all` target so `cmake --build … --target
# package` (Stage C bundle) doesn't drag them through the link step.
add_subdirectory(test EXCLUDE_FROM_ALL)

endif() # NOT ECO_GLIBC_OUTPUT_RUNTIME (ecor + test)

if(NOT ECO_FRONTEND_ONLY)
    # MLIR-based code generation
    add_subdirectory(runtime/src/codegen)

    # Elm kernel C++ implementation
    add_subdirectory(elm-kernel-cpp)

    # Eco kernel C++ implementation (IO operations)
    add_subdirectory(eco-kernel-cpp)
endif()

# Guida compiler (Elm compiler written in Elm). Gated off in the Stage D
# archive-only mode: compiler/CMakeLists.txt hard-REQUIREs node + pnpm at
# configure time, neither of which the glibc-runtime builder image has.
if(NOT ECO_GLIBC_OUTPUT_RUNTIME)
    add_subdirectory(compiler)
endif()

#-------------------------------------------------------------------------------
# Stage C: install rules for the distribution bundle
#
# Placed at the top level (rather than each subdirectory) because every
# target referenced here lives in a different subdir, and CMake processes
# install() calls in subdir order. Putting the rules here, after every
# `add_subdirectory(...)`, lets us reference all targets in one place.
#
# Bundle scope is musl-only (Stage B output ABI); the legacy non-MUSL
# build doesn't ship an installable tree. See plans/stage-c-bundle-runtime.md.
#
# Layout produced:
#   <prefix>/bin/eco
#   <prefix>/lib/eco-runtime/ld.lld
#   <prefix>/lib/eco-runtime/{libc,libc++,libc++abi,libunwind,libclang_rt.builtins-*}.a
#   <prefix>/lib/eco-runtime/{libcurl,libssl,libcrypto,libzip,libz}.a
#   <prefix>/lib/eco-runtime/crt/{crt1,crti,crtn,clang_rt.crtbegin-*,clang_rt.crtend-*}.o
#   <prefix>/lib/eco-runtime/project/lib{ElmKernel_*,EcoKernel_*,Eco*Static}.a
#-------------------------------------------------------------------------------
option(ECO_BUNDLE_STRIP
       "Strip debug info from bundled project archives so AOT-built binaries \
are smaller. Turn OFF to keep debug symbols available in produced executables."
       ON)

if(ECO_STATIC_MUSL)
    # All bundle install rules are tagged with COMPONENT Bundle so that CPack
    # can package this component alone — skipping the auto-generated install
    # rules from add_mlir_library() (libEcoDialect.a etc. under lib/) and from
    # FetchContent (libcurl headers, CURL CMake config, libcurl.pc, etc.).
    # Without this, those land in the bundle and bloat it from ~50 MB to ~98 MB.

    # System static archives + LLVM libunwind. Variables come from
    # runtime/src/codegen/CMakeLists.txt's Stage B.5 query block.
    install(FILES
        ${ECO_LIBC_A} ${ECO_LIBCXX_A} ${ECO_LIBCXXABI_A}
        ${LLVM_LIBUNWIND_LIBRARY} ${ECO_COMPILER_RT_BUILTINS_A}
        ${OPENSSL_SSL_LIBRARY} ${OPENSSL_CRYPTO_LIBRARY} ${ECO_LIBZ_A}
        DESTINATION lib/eco-runtime
        COMPONENT Bundle)

    # crt objects.
    install(FILES
        ${ECO_CRT1_O_STATIC} ${ECO_CRTI_O} ${ECO_CRTN_O}
        ${ECO_CRTBEGIN_O_STATIC} ${ECO_CRTEND_O_STATIC}
        DESTINATION lib/eco-runtime/crt
        COMPONENT Bundle)

    # Bundled static linker, built statically by the Stage 1 LLVM image.
    install(PROGRAMS ${ECO_BUNDLED_LD_LLD}
            DESTINATION lib/eco-runtime
            COMPONENT Bundle)

    # Project static archives. Collect them all then install in one call.
    set(_eco_project_targets
        EcoEntryStatic EcoRuntimeStatic EcoNativeDriverStatic)
    foreach(mod ${ECO_ELM_KERNEL_MODS})
        list(APPEND _eco_project_targets ElmKernel_${mod})
    endforeach()
    foreach(mod ${ECO_KERNEL_MODS})
        list(APPEND _eco_project_targets EcoKernel_${mod})
    endforeach()
    install(TARGETS ${_eco_project_targets}
            ARCHIVE DESTINATION lib/eco-runtime/project
            COMPONENT Bundle)

    # Vendored statics from FetchContent. libcurl_static is created in
    # the top-level FetchContent block at the start of this file; zip
    # comes from eco-kernel-cpp's libzip vendoring.
    install(TARGETS libcurl_static zip
            ARCHIVE DESTINATION lib/eco-runtime
            COMPONENT Bundle)

    # eco/kernel Elm package — the source the bundled `eco` resolves when
    # user code does `import Eco.Console`/`Eco.File`/etc. via the
    # `--local-package eco/kernel=<path>` flag. FILES_MATCHING with positive
    # patterns is sufficient to drop the in-tree C++ siblings under src/eco/
    # (lowercase) and any stale elm-stuff/ cache — neither matches *.elm /
    # *.js / *.dat / elm.json / docs.json.
    install(DIRECTORY ${CMAKE_SOURCE_DIR}/eco-kernel-cpp/
            DESTINATION share/eco/kernel/eco-kernel-cpp
            COMPONENT Bundle
            FILES_MATCHING
                PATTERN "elm.json"
                PATTERN "*.elm"
                PATTERN "*.js"
                PATTERN "artifacts.dat"
                PATTERN "typed-artifacts.dat"
                PATTERN "docs.json"
                REGEX "/elm-stuff(/|$)" EXCLUDE
                REGEX "/src/eco(/|$)" EXCLUDE)

    # Starter examples — Elm sources only. The in-tree examples/ IS the hello
    # project (elm.json + src/Hello.elm at its root), so install its contents
    # into share/eco/examples/hello/ to give us room for sibling examples
    # later. The prebuilt examples/hello ELF doesn't match the *.elm /
    # elm.json filter and drops out.
    install(DIRECTORY ${CMAKE_SOURCE_DIR}/examples/
            DESTINATION share/eco/examples/hello
            COMPONENT Bundle
            FILES_MATCHING
                PATTERN "elm.json"
                PATTERN "*.elm")

    # Stage D: merge the Debian-built glibc output-runtime tree into the
    # bundle. ECO_GLIBC_RUNTIME_TREE points at the tree staged by the
    # eco-glibc-runtime-tree target of a glibc-host configure (COPY
    # --from=glibc-runtime in docker/static-build.Dockerfile). The bundle
    # stays buildable without it — eco then refuses .so/.node outputs with
    # the capability error in EcoNativeDriver.cpp. Declared BEFORE the
    # ECO_BUNDLE_STRIP rule below so its GLOB_RECURSE (which already spans
    # lib/eco-runtime recursively) covers the glibc/ subtree at strip time.
    # See plans/stage-d-hybrid-link-profiles.md (step 3).
    if(ECO_GLIBC_RUNTIME_TREE)
        if(NOT EXISTS "${ECO_GLIBC_RUNTIME_TREE}")
            message(FATAL_ERROR
                "ECO_GLIBC_RUNTIME_TREE does not exist: ${ECO_GLIBC_RUNTIME_TREE}")
        endif()
        install(DIRECTORY ${ECO_GLIBC_RUNTIME_TREE}/
                DESTINATION lib/eco-runtime/glibc
                COMPONENT Bundle)
        message(STATUS "Eco bundle: Stage D glibc output runtime from ${ECO_GLIBC_RUNTIME_TREE}")
    else()
        message(STATUS "Eco bundle: no ECO_GLIBC_RUNTIME_TREE — .so/.node outputs disabled in this bundle")
    endif()

    # Strip debug info from every bundled archive AND crt object. The bundled
    # static ld.lld is built without zlib support (LLVM_ENABLE_ZLIB=OFF inherited
    # from the LLVM base image), so it cannot decompress the ELFCOMPRESS_ZLIB
    # .debug_* sections in Alpine's musl libc.a / crt objects / openssl statics;
    # stripping removes those sections entirely. CPACK_STRIP_FILES only handles
    # executables and .so's, not static archives or .o files.
    #
    # Two correctness details — both previously let compressed sections reach the
    # bundle, surfacing only once a real (zlib-less) static ld.lld shipped:
    #   - Glob *.o as well as *.a: the crt objects (crt1/crti/crtn,
    #     clang_rt.crtbegin/end) are .o and were never covered.
    #   - Prefix with $ENV{DESTDIR}: under CPack the staged tree lives at
    #     $ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}; globbing the bare prefix matched
    #     nothing during packaging, so the .a shipped unstripped.
    if(ECO_BUNDLE_STRIP)
        install(CODE "
            set(_eco_rt \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/lib/eco-runtime\")
            file(GLOB_RECURSE _bundle_objs \"\${_eco_rt}/*.a\" \"\${_eco_rt}/*.o\")
            foreach(_o \${_bundle_objs})
                execute_process(
                    COMMAND ${CMAKE_STRIP} --strip-debug \${_o}
                    RESULT_VARIABLE _eco_strip_rc)
                if(NOT _eco_strip_rc EQUAL 0)
                    message(FATAL_ERROR
                        \"Stage C: strip --strip-debug failed on \${_o} (rc=\${_eco_strip_rc})\")
                endif()
            endforeach()
        " COMPONENT Bundle)
    endif()
endif()

#-------------------------------------------------------------------------------
# Stage D (Debian side): stage the glibc output-runtime tree.
#
# Archive-only mode (see the ECO_GLIBC_OUTPUT_RUNTIME option above): builds
# the glibc-ABI, PIC archive set that the musl bundle ships under
# lib/eco-runtime/glibc/, plus the glibc/gcc CRT objects, then runs a PIC
# audit + glibc-floor computation (cmake/GlibcRuntimeAudit.cmake). Consumed
# by the Alpine bundle configure via -DECO_GLIBC_RUNTIME_TREE=<out>.
# See plans/stage-d-hybrid-link-profiles.md (step 2).
#-------------------------------------------------------------------------------
if(ECO_GLIBC_OUTPUT_RUNTIME)
    set(ECO_GLIBC_RUNTIME_TREE_OUT "${CMAKE_BINARY_DIR}/glibc-runtime-tree"
        CACHE PATH "Staging dir for the Stage D glibc output-runtime tree")

    # LLVM runtime statics (libc++/libc++abi/libunwind/compiler-rt
    # builtins), glibc-targeting. Sourced from the HOST toolchain's
    # packages — on the glibc-runtime Docker stage that's Debian apt
    # (libc++-dev, libc++abi-dev, libclang-rt-dev, libunwind-XX-dev) —
    # mirroring exactly how the musl side takes them from Alpine apk.
    # Discovery reuses the musl block's mechanisms: clang
    # -print-file-name for libc++/libc++abi, --print-libgcc-file-name
    # for the builtins, and cmake/LLVMLibunwind.cmake's result for
    # libunwind (point LLVM_INSTALL_PREFIX at e.g. /usr/lib/llvm-14 for
    # apt layouts — its lib/ + include/ match the expected shape).
    # PIC-ness of the distro archives is NOT assumed: the staging
    # audit's trial links are the gate.
    # ECO_GLIBC_LLVM_RUNTIMES_DIR overrides discovery entirely with a
    # dir holding the four canonical basenames (testing / exotic hosts).
    set(ECO_GLIBC_LLVM_RUNTIMES_DIR ""
        CACHE PATH "Override dir holding glibc-PIC libc++.a/libc++abi.a/libunwind.a/libclang_rt.builtins-x86_64.a (empty = discover from host toolchain)")
    if(ECO_GLIBC_LLVM_RUNTIMES_DIR)
        set(ECO_GLIBC_LIBCXX_A    "${ECO_GLIBC_LLVM_RUNTIMES_DIR}/libc++.a")
        set(ECO_GLIBC_LIBCXXABI_A "${ECO_GLIBC_LLVM_RUNTIMES_DIR}/libc++abi.a")
        set(ECO_GLIBC_UNWIND_A    "${ECO_GLIBC_LLVM_RUNTIMES_DIR}/libunwind.a")
        set(ECO_GLIBC_BUILTINS_A  "${ECO_GLIBC_LLVM_RUNTIMES_DIR}/libclang_rt.builtins-x86_64.a")
    else()
        _eco_query_clang_path(ECO_GLIBC_LIBCXX_A    libc++.a)
        _eco_query_clang_path(ECO_GLIBC_LIBCXXABI_A libc++abi.a)
        execute_process(
            COMMAND ${CMAKE_C_COMPILER} --print-libgcc-file-name -rtlib=compiler-rt
            OUTPUT_VARIABLE ECO_GLIBC_BUILTINS_A
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET)
        get_filename_component(ECO_GLIBC_BUILTINS_A "${ECO_GLIBC_BUILTINS_A}" REALPATH)
        # LLVMLibunwind.cmake already found the static archive (ECO_STATIC
        # is ON in this mode) — reusing it guarantees the staged libunwind
        # matches the headers EcoRuntimeStatic compiled against.
        set(ECO_GLIBC_UNWIND_A "${LLVM_LIBUNWIND_LIBRARY}")
    endif()
    # glibc's static link glue. `atexit`, `at_quick_exit`, `pthread_atfork`,
    # `__stack_chk_fail_local` and the old `__libc_csu_*` are NOT dynamically
    # exported by libc.so.6 — they live only in libc_nonshared.a, the static
    # half of glibc's `-lc` (which is the GNU ld script
    #   GROUP ( libc.so.6 libc_nonshared.a ) ).
    # The Stage D recipe links no libc (symbols bind from the host at load),
    # so without this archive a produced .so/.node references `atexit`
    # (eco_embed.cpp registers an atexit teardown hook) with nothing to
    # resolve it → "undefined symbol: atexit" at dlopen, on EVERY glibc host.
    # Its members call __cxa_atexit (dynamic, exported by libc.so.6) +
    # __dso_handle (from crtbeginS.o), so shipping it adds NO NEEDED entry.
    _eco_query_clang_path(ECO_GLIBC_LIBC_NONSHARED_A libc_nonshared.a)
    foreach(_v ECO_GLIBC_LIBCXX_A ECO_GLIBC_LIBCXXABI_A ECO_GLIBC_UNWIND_A
               ECO_GLIBC_BUILTINS_A ECO_GLIBC_LIBC_NONSHARED_A)
        if(NOT IS_ABSOLUTE "${${_v}}" OR NOT EXISTS "${${_v}}")
            message(FATAL_ERROR "Stage D: ${_v} did not resolve to an existing file: "
                "'${${_v}}'. Install the LLVM runtime dev packages "
                "(Debian: libc++-dev libc++abi-dev libclang-rt-dev libunwind-<N>-dev, "
                "with -DLLVM_INSTALL_PREFIX=/usr/lib/llvm-<N>) or set "
                "ECO_GLIBC_LLVM_RUNTIMES_DIR.")
        endif()
    endforeach()
    message(STATUS "Stage D glibc runtime statics:")
    message(STATUS "  libc++.a:    ${ECO_GLIBC_LIBCXX_A}")
    message(STATUS "  libc++abi.a: ${ECO_GLIBC_LIBCXXABI_A}")
    message(STATUS "  libunwind.a: ${ECO_GLIBC_UNWIND_A}")
    message(STATUS "  builtins.a:  ${ECO_GLIBC_BUILTINS_A}")
    message(STATUS "  libc_nonshared.a: ${ECO_GLIBC_LIBC_NONSHARED_A}")

    if(NOT TARGET EcoNodeGlue)
        message(FATAL_ERROR "Stage D: EcoNodeGlue target missing — the vendored "
            "node-api headers (runtime/third_party/node-api-headers) should make it "
            "unconditional; check the find_path in runtime/src/codegen/CMakeLists.txt")
    endif()

    # Project archives staged under project/ keep their target basenames
    # (they match the glibc* RuntimeFile declarations in EcoBootConfig.h);
    # dep archives are copied to canonical names; CRT objects come from the
    # clang queries in runtime/src/codegen/CMakeLists.txt, which on this
    # glibc host resolve to the real glibc/gcc files. Deliberately NOT
    # staged: EcoEntryStatic (no glibc consumer until dynamic executables)
    # and EcoNativeDriverStatic (never on the AOT link line; would drag the
    # whole MLIR object graph into this stage).
    set(_glibc_project_files
        $<TARGET_FILE:EcoRuntimeStatic>
        $<TARGET_FILE:EcoEmbedStatic>
        $<TARGET_FILE:EcoNodeGlue>)
    set(_glibc_tree_deps EcoRuntimeStatic EcoEmbedStatic EcoNodeGlue
        libcurl_static zip zlibstatic)
    foreach(mod ${ECO_ELM_KERNEL_MODS})
        list(APPEND _glibc_project_files $<TARGET_FILE:ElmKernel_${mod}>)
        list(APPEND _glibc_tree_deps ElmKernel_${mod})
    endforeach()
    foreach(mod ${ECO_KERNEL_MODS})
        list(APPEND _glibc_project_files $<TARGET_FILE:EcoKernel_${mod}>)
        list(APPEND _glibc_tree_deps EcoKernel_${mod})
    endforeach()

    set(_tree "${ECO_GLIBC_RUNTIME_TREE_OUT}")
    add_custom_target(eco-glibc-runtime-tree
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${_tree}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_tree}/crt" "${_tree}/project"
        COMMAND ${CMAKE_COMMAND} -E copy ${_glibc_project_files} "${_tree}/project"
        COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:libcurl_static> "${_tree}/libcurl.a"
        COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:zip>            "${_tree}/libzip.a"
        COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:zlibstatic>     "${_tree}/libz.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${OPENSSL_SSL_LIBRARY}"      "${_tree}/libssl.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${OPENSSL_CRYPTO_LIBRARY}"   "${_tree}/libcrypto.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_GLIBC_LIBCXX_A}"    "${_tree}/libc++.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_GLIBC_LIBCXXABI_A}" "${_tree}/libc++abi.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_GLIBC_UNWIND_A}"    "${_tree}/libunwind.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_GLIBC_BUILTINS_A}"  "${_tree}/libclang_rt.builtins-x86_64.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_GLIBC_LIBC_NONSHARED_A}" "${_tree}/libc_nonshared.a"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_CRTI_O}"     "${_tree}/crt/crti.o"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_CRTN_O}"     "${_tree}/crt/crtn.o"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_CRTBEGIN_O}" "${_tree}/crt/crtbeginS.o"
        COMMAND ${CMAKE_COMMAND} -E copy "${ECO_CRTEND_O}"   "${_tree}/crt/crtendS.o"
        COMMAND ${CMAKE_COMMAND}
            -DTREE=${_tree}
            -P ${CMAKE_SOURCE_DIR}/cmake/GlibcRuntimeAudit.cmake
        DEPENDS ${_glibc_tree_deps}
        COMMENT "Stage D: staging + auditing the glibc output-runtime tree at ${_tree}"
        VERBATIM)
endif()

#-------------------------------------------------------------------------------
# Stage C: distribution bundles via CPack
#
# Produces `eco-0.1.0-x86_64-linux-musl.{tar.gz,zip}` via `cmake --build
# <build> --target package`. The TGZ and ZIP generators package the install
# tree defined by the `install()` rules in compiler/ and runtime/src/codegen/.
# Bundle scope is musl-only (Stage B output ABI); see plans/stage-c-bundle-runtime.md.
#-------------------------------------------------------------------------------
if(ECO_STATIC_MUSL)
    # Package version: the same source of truth as the binary's user-facing
    # version (see compiler/CMakeLists.txt). version.txt holds the baseline;
    # a tagged release passes -DECO_VERSION_OVERRIDE=<v> to stamp both the
    # bundle names and `eco --version` with one knob. Unlike the binary's
    # version we never append the -dev-<git-describe> suffix here — package
    # filenames must be a clean semver.
    file(READ "${CMAKE_SOURCE_DIR}/version.txt" ECO_PACKAGE_VERSION)
    string(STRIP "${ECO_PACKAGE_VERSION}" ECO_PACKAGE_VERSION)
    if(ECO_VERSION_OVERRIDE)
        set(ECO_PACKAGE_VERSION "${ECO_VERSION_OVERRIDE}")
    endif()
    message(STATUS "Eco bundle version: ${ECO_PACKAGE_VERSION}")

    set(CPACK_PACKAGE_NAME "eco")
    set(CPACK_PACKAGE_VERSION "${ECO_PACKAGE_VERSION}")
    set(CPACK_PACKAGE_FILE_NAME "eco-${ECO_PACKAGE_VERSION}-x86_64-linux-musl")
    # DEB joins TGZ;ZIP for v0.1.0 (plans/release-bundle-v0.1.0.md). The
    # per-generator install prefix is set in cmake/CPackProjectConfig.cmake.
    set(CPACK_GENERATOR "TGZ;ZIP;DEB")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
        "Eco — Elm compiler with static AOT runtime (Stage B / MUSL)")
    set(CPACK_PACKAGE_VENDOR "thesett")
    # Strips the eco binary and bundled ld.lld at package time. Static
    # archives are stripped separately via install(CODE …) in
    # runtime/src/codegen/CMakeLists.txt, gated on ECO_BUNDLE_STRIP.
    set(CPACK_STRIP_FILES ON)
    # Restrict the package to the explicit Bundle component so add_mlir_library
    # and FetchContent's auto-installed install rules (libEcoDialect.a, curl
    # headers, cmake config, libcurl.pc, etc.) do not pollute the archive.
    set(CPACK_COMPONENTS_ALL Bundle)
    set(CPACK_ARCHIVE_COMPONENT_INSTALL ON)
    set(CPACK_DEB_COMPONENT_INSTALL ON)
    # Archive component installs default to <component-name>/-prefixed file
    # names (eco-0.1.0-…-Bundle.tar.gz). Override so we get the bare name.
    set(CPACK_ARCHIVE_BUNDLE_FILE_NAME "${CPACK_PACKAGE_FILE_NAME}")

    # Debian package metadata. Static binary → empty Depends. /usr/local
    # prefix is set per-generator in cmake/CPackProjectConfig.cmake.
    set(CPACK_DEBIAN_PACKAGE_NAME         "eco")
    set(CPACK_DEBIAN_PACKAGE_VERSION      "${CPACK_PACKAGE_VERSION}")
    set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "amd64")
    set(CPACK_DEBIAN_PACKAGE_MAINTAINER
        "thesett <anthropic@thesett.com>")
    set(CPACK_DEBIAN_PACKAGE_SECTION      "devel")
    set(CPACK_DEBIAN_PACKAGE_DEPENDS      "")
    set(CPACK_DEBIAN_PACKAGE_DESCRIPTION
        "Eco - Elm compiler with static AOT runtime (experimental Stage B MUSL build)")
    # Bundle component → single .deb (no -bundle suffix in the filename).
    set(CPACK_DEBIAN_BUNDLE_FILE_NAME     "eco_${ECO_PACKAGE_VERSION}_amd64.deb")
    set(CPACK_DEBIAN_BUNDLE_PACKAGE_NAME  "eco")

    # Per-generator overrides (DEB → /usr/local prefix + Debian-style file
    # name). Loaded by CPack once per generator with ${CPACK_GENERATOR} set.
    set(CPACK_PROJECT_CONFIG_FILE
        "${CMAKE_SOURCE_DIR}/cmake/CPackProjectConfig.cmake")

    include(CPack)
endif()

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
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test
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
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Gate A: clean, rebuild default ALL + Stage 1, run JIT E2E"
    USES_TERMINAL
)
