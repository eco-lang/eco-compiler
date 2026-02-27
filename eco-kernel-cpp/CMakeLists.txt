cmake_minimum_required(VERSION 3.16)
project(eco-kernel LANGUAGES CXX)

# Eco Kernel C++ Implementation
# Provides kernel IO functions with C-linkage exports for LLVM JIT

# Runtime include directory (for allocator headers)
set(RUNTIME_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../runtime/src)

# Find optional dependencies for Http module
find_package(CURL QUIET)
find_package(OpenSSL QUIET)
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(LIBZIP QUIET libzip)
endif()

if(CURL_FOUND AND OPENSSL_FOUND)
    set(HTTP_AVAILABLE ON)
    message(STATUS "eco-kernel: libcurl and OpenSSL found - Http module will be fully functional")
else()
    set(HTTP_AVAILABLE OFF)
    message(STATUS "eco-kernel: libcurl or OpenSSL not found - Http module will use stubs")
endif()

if(LIBZIP_FOUND)
    message(STATUS "eco-kernel: libzip found - archive extraction available")
else()
    message(STATUS "eco-kernel: libzip not found - archive extraction will use stubs")
endif()

#------------------------------------------------------------------------------
# Per-module static libraries
#------------------------------------------------------------------------------

# File module (file I/O, directory ops, handles, locks)
add_library(EcoKernel_File STATIC
    src/eco/File.cpp
    src/eco/FileExports.cpp
)
target_include_directories(EcoKernel_File PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_File PUBLIC cxx_std_20)

# Console module (stdout/stderr write, stdin read)
add_library(EcoKernel_Console STATIC
    src/eco/Console.cpp
    src/eco/ConsoleExports.cpp
)
target_include_directories(EcoKernel_Console PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Console PUBLIC cxx_std_20)

# Env module (environment variables, CLI args)
add_library(EcoKernel_Env STATIC
    src/eco/Env.cpp
    src/eco/EnvExports.cpp
)
target_include_directories(EcoKernel_Env PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Env PUBLIC cxx_std_20)

# Process module (exit, spawn, wait)
add_library(EcoKernel_Process STATIC
    src/eco/Process.cpp
    src/eco/ProcessExports.cpp
)
target_include_directories(EcoKernel_Process PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Process PUBLIC cxx_std_20)

# MVar module (concurrency primitives)
add_library(EcoKernel_MVar STATIC
    src/eco/MVar.cpp
    src/eco/MVarExports.cpp
)
target_include_directories(EcoKernel_MVar PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_MVar PUBLIC cxx_std_20)

# Runtime module (dirname, random, REPL state)
add_library(EcoKernel_Runtime STATIC
    src/eco/Runtime.cpp
    src/eco/RuntimeExports.cpp
)
target_include_directories(EcoKernel_Runtime PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(EcoKernel_Runtime PUBLIC cxx_std_20)

# Http module (HTTP requests, archive downloads)
add_library(EcoKernel_Http STATIC
    src/eco/Http.cpp
    src/eco/HttpExports.cpp
)
target_include_directories(EcoKernel_Http PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
if(HTTP_AVAILABLE)
    target_link_libraries(EcoKernel_Http PRIVATE CURL::libcurl OpenSSL::SSL OpenSSL::Crypto)
    target_compile_definitions(EcoKernel_Http PRIVATE HTTP_CURL_AVAILABLE=1)
endif()
if(LIBZIP_FOUND)
    target_link_libraries(EcoKernel_Http PRIVATE ${LIBZIP_LIBRARIES})
    target_include_directories(EcoKernel_Http PRIVATE ${LIBZIP_INCLUDE_DIRS})
    target_compile_definitions(EcoKernel_Http PRIVATE LIBZIP_AVAILABLE=1)
endif()
target_compile_features(EcoKernel_Http PUBLIC cxx_std_20)

#------------------------------------------------------------------------------
# Combined convenience library
#------------------------------------------------------------------------------

add_library(EcoKernel INTERFACE)
target_link_libraries(EcoKernel INTERFACE
    EcoKernel_File
    EcoKernel_Console
    EcoKernel_Env
    EcoKernel_Process
    EcoKernel_MVar
    EcoKernel_Runtime
    EcoKernel_Http
)

# Keep asserts enabled even in release builds
foreach(target
    EcoKernel_File EcoKernel_Console EcoKernel_Env
    EcoKernel_Process EcoKernel_MVar EcoKernel_Runtime
    EcoKernel_Http
)
    target_compile_options(${target} PRIVATE -UNDEBUG)
endforeach()
