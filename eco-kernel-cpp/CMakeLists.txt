cmake_minimum_required(VERSION 3.16)
project(eco-kernel LANGUAGES CXX)

# Eco Kernel C++ Implementation
# Provides kernel IO functions with C-linkage exports for LLVM JIT

# Runtime include directory (for allocator headers)
set(RUNTIME_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../runtime/src)

# libcurl, OpenSSL and libzip. No eco/kernel module uses them since EcoKernel_Http was removed
# (plans/compiler-io-on-eco-system.md); they are still found or vendored here because the AOT and
# bundle link lines and the static builds name them (ECO_KERNEL_LIBZIP_* below), which a follow-up
# can drop.
#
# Under ECO_STATIC (Stage A in plans/static-link-eco-binary.md):
#   - OpenSSL via OPENSSL_USE_STATIC_LIBS=TRUE → libssl.a / libcrypto.a
#   - libcurl via pkg-config's STATIC_LIBRARIES (folds in Libs.private:
#     nghttp2, idn2, psl, brotli, zstd, ldap, krb5, …)
#   - libzip vendored via FetchContent (Debian ships only libzip.so)
#
# Under the default dynamic build the behavior is unchanged: find_package
# picks .so files and we link against the system-shared libs.
# OPENSSL_USE_STATIC_LIBS / ZLIB_USE_STATIC_LIBS / CMAKE_FIND_LIBRARY_SUFFIXES
# are set at the top-level CMakeLists.txt when ECO_STATIC=ON — they must be
# in effect before any sibling subdirectory's find_package call. On Windows
# OpenSSL is eliminated entirely (schannel + BCrypt replace it — see
# plans/build-on-windows.md Dependency stack); the win-build path links
# against the OS-provided crypt32/bcrypt/secur32 import libs.
if(NOT WIN32)
    find_package(OpenSSL REQUIRED)
endif()

# Under ECO_STATIC OR WIN32 the vendored libcurl_static target is created
# by the top-level CMakeLists.txt before any subdirectory is added (so
# both elm-kernel-cpp and eco-kernel-cpp can link against it without an
# ordering hazard). Here we only need to set CURL_FOUND and run the
# dynamic find_package if we're not in static/Windows mode.
if(ECO_STATIC OR WIN32)
    set(CURL_FOUND TRUE)
else()
    find_package(CURL REQUIRED)
endif()

# libzip resolution. The default path (LIBZIP_FOUND from pkg-config) wires
# the system .so. We vendor libzip via FetchContent when:
#   - ECO_STATIC: Debian's libzip-dev ships only the shared object — see
#     Stage A, Step 4 in plans/static-link-eco-binary.md.
#   - APPLE: brew's libzip formula ships only libzip.dylib (no static .a)
#     and macOS has no SDK libzip — and AOT-built binaries must be free
#     of a brew /opt/homebrew runtime dep. Vendoring gives a static
#     libzip.a we can bundle under lib/eco-runtime/project/.
if(ECO_STATIC OR APPLE OR WIN32)
    include(FetchContent)
    # libzip 1.11.4 (Aug 2024) — stable, ships a CMake target named `zip`.
    FetchContent_Declare(libzip_vendored
        GIT_REPOSITORY https://github.com/nih-at/libzip.git
        GIT_TAG v1.11.4
        GIT_SHALLOW TRUE
    )
    # Constrain libzip's optional features to what EcoKernel_Http actually
    # uses: ZIP reading only. Disabling these prevents libzip from pulling
    # in bzip2 / lzma / zstd / openssl-for-zip-encryption as additional
    # .so dependencies we'd then need static counterparts of.
    set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)
    set(LIBZIP_DO_INSTALL    OFF CACHE BOOL "" FORCE)
    set(ENABLE_COMMONCRYPTO  OFF CACHE BOOL "" FORCE)
    set(ENABLE_GNUTLS        OFF CACHE BOOL "" FORCE)
    set(ENABLE_MBEDTLS       OFF CACHE BOOL "" FORCE)
    set(ENABLE_OPENSSL       OFF CACHE BOOL "" FORCE)
    set(ENABLE_WINDOWS_CRYPTO OFF CACHE BOOL "" FORCE)
    set(ENABLE_BZIP2         OFF CACHE BOOL "" FORCE)
    set(ENABLE_LZMA          OFF CACHE BOOL "" FORCE)
    set(ENABLE_ZSTD          OFF CACHE BOOL "" FORCE)
    set(BUILD_TOOLS          OFF CACHE BOOL "" FORCE)
    set(BUILD_REGRESS        OFF CACHE BOOL "" FORCE)
    set(BUILD_EXAMPLES       OFF CACHE BOOL "" FORCE)
    set(BUILD_DOC            OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(libzip_vendored)
    set(LIBZIP_FOUND TRUE)
    if(APPLE)
        message(STATUS "eco-kernel: libzip vendored via FetchContent (APPLE) - archive extraction available")
    elseif(WIN32)
        message(STATUS "eco-kernel: libzip vendored via FetchContent (WIN32) - archive extraction available")
    else()
        message(STATUS "eco-kernel: libzip vendored via FetchContent (ECO_STATIC) - archive extraction available")
    endif()
else()
    find_package(PkgConfig REQUIRED)
    # IMPORTED_TARGET so PkgConfig::LIBZIP carries the library search path
    # (-L) alongside -lzip. Bare ${LIBZIP_LIBRARIES} is just the name "zip";
    # that resolves on Linux only because system libzip sits in the default
    # linker path, but Homebrew installs to /opt/homebrew/opt/libzip/lib which
    # the linker does not search, so the link fails with "library 'zip' not
    # found" on macOS.
    pkg_check_modules(LIBZIP REQUIRED IMPORTED_TARGET libzip)
    message(STATUS "eco-kernel: libzip found - archive extraction available")
endif()

# Re-publish libzip detection at the parent scope so the codegen layer can
# decide whether to append `-lzip` to the AOT linker command line invoked by
# eco-boot-native (Http.cpp's libzip symbols come from the EcoKernel_Http
# static archive's PRIVATE link interface and aren't transitively pulled in).
if(LIBZIP_FOUND AND NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(ECO_KERNEL_LIBZIP_FOUND TRUE PARENT_SCOPE)
    if(ECO_STATIC OR APPLE OR WIN32)
        # FetchContent target name is `zip` (libzip's CMakeLists exports it).
        set(ECO_KERNEL_LIBZIP_LIBRARIES "zip" PARENT_SCOPE)
    else()
        set(ECO_KERNEL_LIBZIP_LIBRARIES "${LIBZIP_LIBRARIES}" PARENT_SCOPE)
    endif()
endif()

#------------------------------------------------------------------------------
# Per-module static libraries
#------------------------------------------------------------------------------

# MVar module (concurrency primitives)
add_library(EcoKernel_MVar STATIC
    src/eco-kernel/MVar.cpp
    src/eco-kernel/MVarExports.cpp
)
target_include_directories(EcoKernel_MVar PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_MVar PUBLIC cxx_std_20)

# Hash module (allocation-free native string hashing for Elm-side hash tables)
add_library(EcoKernel_Hash STATIC
    src/eco-kernel/Hash.cpp
    src/eco-kernel/HashExports.cpp
)
target_include_directories(EcoKernel_Hash PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Hash PUBLIC cxx_std_20)

# GC module (explicit collections, plans/frontend-heap-release.md §4, HEAP_076)
add_library(EcoKernel_GC STATIC
    src/eco-kernel/GC.cpp
    src/eco-kernel/GCExports.cpp
)
target_include_directories(EcoKernel_GC PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_GC PUBLIC cxx_std_20)

# Crash module (unrecoverable error handling)
add_library(EcoKernel_Crash STATIC
    src/eco-kernel/Crash.cpp
    src/eco-kernel/CrashExports.cpp
)
target_include_directories(EcoKernel_Crash PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Crash PUBLIC cxx_std_20)

# NativeDriver module (in-process MLIR -> ELF lowering bridge for `eco`)
# Strong impl of eco_native_lower_and_link lives in EcoNativeDriverStatic
# (runtime/src/codegen). This module declares it weak so binaries without
# the driver library still link.
add_library(EcoKernel_NativeDriver STATIC
    src/eco-kernel/NativeDriver.cpp
    src/eco-kernel/NativeDriverExports.cpp
)
target_include_directories(EcoKernel_NativeDriver PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
# eco_native_lower_and_link declarations live here, but the strong
# implementation is provided by EcoNativeDriverStatic in the codegen layer.
target_include_directories(EcoKernel_NativeDriver PRIVATE
    ${CMAKE_SOURCE_DIR}/runtime/src/codegen
)
target_compile_features(EcoKernel_NativeDriver PUBLIC cxx_std_20)

#------------------------------------------------------------------------------
# Combined convenience library
#------------------------------------------------------------------------------

add_library(EcoKernel INTERFACE)
target_link_libraries(EcoKernel INTERFACE
    EcoKernel_MVar
    EcoKernel_Hash
    EcoKernel_NativeDriver
    EcoKernel_GC
    EcoKernel_Crash
)

# Asserts on iff ECO_ASSERTS_ON (default ON for non-Release).
if(ECO_ASSERTS_ON)
    foreach(target
        EcoKernel_MVar EcoKernel_Hash
        EcoKernel_NativeDriver EcoKernel_GC
        EcoKernel_Crash
    )
        target_compile_options(${target} PRIVATE -UNDEBUG)
    endforeach()
endif()

