cmake_minimum_required(VERSION 3.16)
project(eco-system LANGUAGES CXX)

# Eco System C++ implementation: the kernels of the public eco/system Elm package
# (plans/eco-system-library.md). One static library per kernel module, named
# EcoSystem_<Module>. The module list is ECO_SYSTEM_MODS in
# runtime/src/codegen/CMakeLists.txt, which also feeds the AOT link line
# (EcoBootConfig.h), the eco/eco-boot-native dependencies and the bundle install
# rules. EcoSystem_Core holds the services shared by every module (§3.4).

set(RUNTIME_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../runtime/src)
set(ECO_KERNEL_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../eco-kernel-cpp/src)

# eco_system_module(<Mod> POSIX <sources...> [WIN32 <sources...>])
#
# POSIX sources build on Linux and macOS. On Windows the WIN32 sources are used
# instead (stubs that fail with ENOTSUP or crash with a clear message, §1); when no
# WIN32 sources are given the POSIX ones are used (portable modules).
function(eco_system_module mod)
    cmake_parse_arguments(ARG "" "" "POSIX;WIN32" ${ARGN})
    if(WIN32 AND ARG_WIN32)
        set(srcs ${ARG_WIN32})
    else()
        set(srcs ${ARG_POSIX})
    endif()
    add_library(EcoSystem_${mod} STATIC ${srcs})
    # Headers only from eco-kernel-cpp (KernelHelpers/ExportHelpers); eco/system
    # never links EcoKernel_* (plans §3.3.2).
    target_include_directories(EcoSystem_${mod} PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${RUNTIME_INCLUDE_DIR}
        ${ECO_KERNEL_INCLUDE_DIR})
    target_compile_features(EcoSystem_${mod} PUBLIC cxx_std_20)
    if(NOT mod STREQUAL "Core")
        target_link_libraries(EcoSystem_${mod} PUBLIC EcoSystem_Core)
    endif()
    if(ECO_ASSERTS_ON)
        target_compile_options(EcoSystem_${mod} PRIVATE -UNDEBUG)
    endif()
endfunction()

#------------------------------------------------------------------------------
# Per-module static libraries
#------------------------------------------------------------------------------

# EcoSystem_Core: the services shared by every module (§3.4) and the helper
# header every kernel starts with (Core.hpp, §3.3.2). The same sources build on
# Windows, where the POSIX services are stubs (§1).
set(ECO_SYSTEM_CORE_SRCS
    src/eco-system/Core/Core.cpp
    src/eco-system/Core/ErrnoNames.cpp
    src/eco-system/Core/KillHandle.cpp
    src/eco-system/Core/AsyncSources.cpp
    src/eco-system/Core/SysWorkPool.cpp
    src/eco-system/Core/FdChannel.cpp
    src/eco-system/Core/ChannelDrain.cpp
    src/eco-system/Core/SignalService.cpp
    src/eco-system/Core/SocketUtil.cpp
    src/eco-system/Core/IoReactor.cpp)
eco_system_module(Core         POSIX ${ECO_SYSTEM_CORE_SRCS})
find_package(Threads REQUIRED)
target_link_libraries(EcoSystem_Core PUBLIC Threads::Threads)
eco_system_module(System       POSIX
    src/eco-system/System/System.cpp
    src/eco-system/System/SystemExports.cpp
    src/eco-system/System/SystemManager.cpp)
# System reads the stdio pairs out of the stream table (environment, §3.7).
target_link_libraries(EcoSystem_System PUBLIC EcoSystem_Stream)
eco_system_module(Stream       POSIX
    src/eco-system/Stream/Stream.cpp
    src/eco-system/Stream/StreamCodec.cpp
    src/eco-system/Stream/StreamPipe.cpp
    src/eco-system/Stream/StreamExports.cpp)
# zlib for the compression codecs (StreamCodec.cpp, Phase 6). Where the
# top-level CMakeLists vendors zlib — Windows (the `ZLIB` FetchContent with
# OVERRIDE_FIND_PACKAGE) and the Stage D glibc-runtime archive build
# (`zlib_vendored`) — link that `zlibstatic` target, exactly what libzip and
# libcurl get there. Everywhere else find_package(ZLIB): the system libz on
# Linux/macOS dynamic builds, and under ECO_STATIC the static libz.a, because
# ZLIB_USE_STATIC_LIBS is set before any subdirectory is added. AOT links
# add zlib themselves (EcoNativeDriver.cpp: -lz, libzStaticA,
# windowsZlibA).
if(TARGET zlibstatic)
    target_link_libraries(EcoSystem_Stream PUBLIC zlibstatic)
    if(DEFINED zlib_vendored_SOURCE_DIR)
        target_include_directories(EcoSystem_Stream PRIVATE
            ${zlib_vendored_SOURCE_DIR} ${zlib_vendored_BINARY_DIR})
    endif()
else()
    find_package(ZLIB REQUIRED)
    target_link_libraries(EcoSystem_Stream PUBLIC ZLIB::ZLIB)
endif()
eco_system_module(FileSystem   POSIX
    src/eco-system/FileSystem/FileSystem.cpp
    src/eco-system/FileSystem/FileSystemExports.cpp
    src/eco-system/FileSystem/FileSystemOps.cpp
    src/eco-system/FileSystem/FileSystemManager.cpp
    src/eco-system/FileSystem/WatchService.cpp
    WIN32
    src/eco-system/FileSystem/FileSystem.cpp
    src/eco-system/FileSystem/FileSystemExports.cpp
    src/eco-system/FileSystem/FileSystemOpsWin32.cpp
    src/eco-system/FileSystem/FileSystemManager.cpp
    src/eco-system/FileSystem/WatchService.cpp)
# File streams are FdSource/FdSink pairs in the stream table (Phase 4 step 4.5).
target_link_libraries(EcoSystem_FileSystem PUBLIC EcoSystem_Stream)
eco_system_module(ChildProcess POSIX
    src/eco-system/ChildProcess/Spawn.cpp
    src/eco-system/ChildProcess/ChildProcess.cpp
    src/eco-system/ChildProcess/ChildProcessExports.cpp
    src/eco-system/ChildProcess/ChildProcessManager.cpp)
# External connections hand the child's pipes to Elm as streams (Phase 5).
target_link_libraries(EcoSystem_ChildProcess PUBLIC EcoSystem_Stream)
# posix_spawn_file_actions_addchdir_np (glibc >= 2.29, musl >= 1.1.24,
# macOS >= 10.15); without it the child runs through /bin/sh to cd (step 5.2).
if(NOT WIN32)
    include(CheckCXXSymbolExists)
    check_cxx_symbol_exists(posix_spawn_file_actions_addchdir_np "spawn.h"
        ECO_SYSTEM_HAVE_ADDCHDIR_NP)
    if(ECO_SYSTEM_HAVE_ADDCHDIR_NP)
        target_compile_definitions(EcoSystem_ChildProcess PRIVATE ECO_SYSTEM_HAVE_ADDCHDIR_NP=1)
    endif()
endif()
eco_system_module(Terminal     POSIX
    src/eco-system/Terminal/Terminal.cpp
    src/eco-system/Terminal/TerminalExports.cpp
    src/eco-system/Terminal/TerminalManager.cpp)
eco_system_module(HttpServer   POSIX
    src/eco-system/HttpServer/Http1.cpp
    src/eco-system/HttpServer/Http2.cpp
    src/eco-system/HttpServer/HttpServer.cpp
    src/eco-system/HttpServer/HttpServerExports.cpp
    src/eco-system/HttpServer/HttpServerManager.cpp
    src/eco-system/HttpServer/HttpServerService.cpp
    src/eco-system/HttpServer/HttpTables.cpp
    src/eco-system/HttpServer/HttpUpgrade.cpp
    WIN32
    src/eco-system/HttpServer/HttpServer.cpp
    src/eco-system/HttpServer/HttpServerExports.cpp
    src/eco-system/HttpServer/HttpServerManager.cpp
    src/eco-system/HttpServer/HttpServerServiceWin32.cpp
    src/eco-system/HttpServer/HttpTables.cpp
    src/eco-system/HttpServer/HttpUpgrade.cpp)
# Connections run on the IoReactor as Conn protocols (plans/eco-system-
# websockets.md §3.4, WS2): listeners in callback mode, Http1Protocol.
# HTTPS (§3.5, WS3): TLS server contexts and transports of EcoSystem_Tls.
# Http.Server.upgradeRequest (§3.6, WS5): the h1 hand-off parks the connection
# as a WebSocket handshake (EcoSystem_WebSocket's HoldProtocol and tables).
target_link_libraries(EcoSystem_HttpServer PUBLIC EcoSystem_Socket EcoSystem_Tls EcoSystem_WebSocket)
# llhttp (Node's HTTP/1.1 parser, MIT) parses requests (Phase 7 step 7.1). The
# release tarball ships the generated C, so no node/TypeScript build is
# needed. It is an OBJECT library whose objects are merged INTO
# libEcoSystem_HttpServer.a: static archives carry no link dependencies, and
# the AOT driver links exactly the EcoSystem_* archives of EcoBootConfig.h,
# so llhttp must be inside the archive (no driver or bundle change).
# SOURCE_SUBDIR points at a directory without a CMakeLists.txt, so
# FetchContent only downloads: llhttp's own CMake project is not added.
# Windows uses the stub service and does not need it (§1).
if(NOT WIN32)
    include(FetchContent)
    FetchContent_Declare(llhttp
        URL https://github.com/nodejs/llhttp/archive/refs/tags/release/v9.2.1.tar.gz
        URL_HASH SHA256=3c163891446e529604b590f9ad097b2e98b5ef7e4d3ddcf1cf98b62ca668f23e
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        SOURCE_SUBDIR eco-no-cmake)
    FetchContent_MakeAvailable(llhttp)
    add_library(llhttp_objects OBJECT
        ${llhttp_SOURCE_DIR}/src/api.c
        ${llhttp_SOURCE_DIR}/src/http.c
        ${llhttp_SOURCE_DIR}/src/llhttp.c)
    target_include_directories(llhttp_objects PUBLIC ${llhttp_SOURCE_DIR}/include)
    set_target_properties(llhttp_objects PROPERTIES
        C_STANDARD 99
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden)
    target_sources(EcoSystem_HttpServer PRIVATE $<TARGET_OBJECTS:llhttp_objects>)
    # PUBLIC: Http1.hpp (the WS5 hand-off hooks) includes llhttp.h.
    target_include_directories(EcoSystem_HttpServer PUBLIC ${llhttp_SOURCE_DIR}/include)
    add_dependencies(EcoSystem_HttpServer llhttp_objects)

    # nghttp2 1.70.0 (MIT) runs HTTP/2 connections (plans/eco-system-websockets.md
    # §3.8, phase WS8): one server session per h2 connection (Http2.cpp), and
    # the WebSocket client's session over HTTP/2 (Http2Client.cpp, §3.9, WS9).
    # "Route B", as llhttp: FetchContent only downloads (SOURCE_SUBDIR has no
    # CMakeLists.txt, so nghttp2's own project is not added), lib/*.c (26 files)
    # build as an OBJECT library whose objects are merged INTO
    # libEcoSystem_WebSocket.a (below; the AOT driver links only EcoSystem_*
    # archives, in one group; EcoSystem_HttpServer links EcoSystem_WebSocket, so
    # Http2.cpp finds them there), and nghttp2ver.h is generated here. Only the
    # library sources are used (no apps, no OpenSSL/libev/jansson).
    FetchContent_Declare(nghttp2
        URL https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz
        URL_HASH SHA256=aa317e2cf9dca6afa0aed68f8fad6ff303ec6982e25a78c75c0b65e2b9b3ded5
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        SOURCE_SUBDIR eco-no-cmake)
    FetchContent_MakeAvailable(nghttp2)
    set(PACKAGE_VERSION "1.70.0")
    set(PACKAGE_VERSION_NUM "0x014600")
    set(ECO_NGHTTP2_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/nghttp2-gen)
    configure_file(${nghttp2_SOURCE_DIR}/lib/includes/nghttp2/nghttp2ver.h.in
        ${ECO_NGHTTP2_GEN_DIR}/nghttp2/nghttp2ver.h @ONLY)
    file(GLOB ECO_NGHTTP2_SRCS ${nghttp2_SOURCE_DIR}/lib/*.c)
    list(LENGTH ECO_NGHTTP2_SRCS ECO_NGHTTP2_NSRCS)
    if(NOT ECO_NGHTTP2_NSRCS EQUAL 26)
        message(FATAL_ERROR "nghttp2: expected 26 lib/*.c files, found ${ECO_NGHTTP2_NSRCS}")
    endif()
    add_library(nghttp2_objects OBJECT ${ECO_NGHTTP2_SRCS})
    # The generated nghttp2ver.h first (the tarball also ships one).
    target_include_directories(nghttp2_objects BEFORE PUBLIC
        ${ECO_NGHTTP2_GEN_DIR}
        ${nghttp2_SOURCE_DIR}/lib/includes)
    target_include_directories(nghttp2_objects PRIVATE ${nghttp2_SOURCE_DIR}/lib)
    target_compile_definitions(nghttp2_objects
        PUBLIC NGHTTP2_STATICLIB
        PRIVATE BUILDING_NGHTTP2 HAVE_ARPA_INET_H HAVE_NETINET_IN_H HAVE_CLOCK_GETTIME
                HAVE_DECL_CLOCK_MONOTONIC=1)
    set_target_properties(nghttp2_objects PROPERTIES
        C_STANDARD 99
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden)
    target_include_directories(EcoSystem_HttpServer PRIVATE
        ${ECO_NGHTTP2_GEN_DIR}
        ${nghttp2_SOURCE_DIR}/lib/includes)
    target_compile_definitions(EcoSystem_HttpServer PRIVATE NGHTTP2_STATICLIB)
    add_dependencies(EcoSystem_HttpServer nghttp2_objects)
endif()
eco_system_module(HttpStream   POSIX
    src/eco-system/HttpStream/HttpStream.cpp
    src/eco-system/HttpStream/HttpStreamExports.cpp
    src/eco-system/HttpStream/HttpTransfer.cpp)
# Response bodies are ChannelSources and stream request bodies are piped into
# a ChannelSink (Phase 8).
target_link_libraries(EcoSystem_HttpStream PUBLIC EcoSystem_Stream)
# libcurl, with the same per-platform selection as EcoKernel_Http
# (eco-kernel-cpp/CMakeLists.txt): the vendored `libcurl_static` target under
# WIN32 (schannel) and ECO_STATIC (created by the top-level CMakeLists before
# any subdirectory), the SDK / system libcurl (CURL::libcurl) otherwise.
# find_package's imported target is directory-scoped, so it is looked up
# here again. AOT links add libcurl themselves (EcoNativeDriver.cpp: -lcurl,
# libcurlStaticA, Darwin curl, windowsLibcurlA).
if(WIN32 OR ECO_STATIC)
    target_link_libraries(EcoSystem_HttpStream PRIVATE libcurl_static)
else()
    find_package(CURL REQUIRED)
    target_link_libraries(EcoSystem_HttpStream PRIVATE CURL::libcurl)
endif()

# Sockets (plans/eco-system-sockets.md §3.1): TCP, Unix and UDP in
# EcoSystem_Socket; TLS in EcoSystem_Tls on OpenSSL 3 (§3.6), linking the
# socket tables and transports of EcoSystem_Socket. OpenSSL is already on
# every native AOT link (sockets plan SF6), so the driver needs no change.
# The stream sockets (S3) run on the IoReactor (Conn, Listener, SocketEvents,
# SocketTables). The same sources build on every platform: on Windows the
# reactor is a stub and the fallible kernels fail with ENOTSUP (§1).
eco_system_module(Socket       POSIX
    src/eco-system/Socket/Conn.cpp
    src/eco-system/Socket/FaceProtocol.cpp
    src/eco-system/Socket/ConnChannel.cpp
    src/eco-system/Socket/Listener.cpp
    src/eco-system/Socket/Socket.cpp
    src/eco-system/Socket/SocketEvents.cpp
    src/eco-system/Socket/SocketExports.cpp
    src/eco-system/Socket/SocketManager.cpp
    src/eco-system/Socket/SocketTables.cpp
    src/eco-system/Socket/Udp.cpp
    src/eco-system/Socket/UdpExports.cpp
    src/eco-system/Socket/UdpManager.cpp)
# Connections are stream pairs in the stream table (§3.3.3).
target_link_libraries(EcoSystem_Socket PUBLIC EcoSystem_Stream)
# TLS (S5): contexts on the SysWorkPool, a memory-BIO transport plugged into
# Conn/ListenerHandler through TransportFactory, and the B.3 kernels. The
# same sources build on Windows, where every OpenSSL part is compiled out
# and the kernels fail ENOTSUP (§1).
eco_system_module(Tls          POSIX
    src/eco-system/Tls/Tls.cpp
    src/eco-system/Tls/TlsContext.cpp
    src/eco-system/Tls/TlsExports.cpp
    src/eco-system/Tls/TlsTransport.cpp)
target_link_libraries(EcoSystem_Tls PUBLIC EcoSystem_Socket)
# OpenSSL on POSIX only: Windows has no OpenSSL in its dependency stack (TLS
# via schannel elsewhere), and its Tls sources are stubs.
if(NOT WIN32)
    find_package(OpenSSL REQUIRED)
    target_link_libraries(EcoSystem_Tls PRIVATE OpenSSL::SSL)
endif()

# WebSockets (plans/eco-system-websockets.md §3.1, §3.6): the RFC 6455 codec
# (WsFrame, WsProtocol) as a connection protocol on the IoReactor, over plain
# and TLS connections, with message streams in the stream table (WsChannel:
# mapped pairs); the kernel side of the handshake (WsHandshake: key/accept
# with OpenSSL SHA-1, RAND and base64, the dial and the upgrade read), the
# main-thread tables and events (WsTables, WsEvents) and the "WebSocket"
# manager; WsDeflate (permessage-deflate, WS7) uses zlib, which comes with
# EcoSystem_Stream (PUBLIC). The same sources build on
# Windows, where the OpenSSL parts are compiled out and the kernels fail
# ENOTSUP (§1).
eco_system_module(WebSocket    POSIX
    src/eco-system/WebSocket/H2StreamPort.cpp
    src/eco-system/WebSocket/Http2Client.cpp
    src/eco-system/WebSocket/WebSocket.cpp
    src/eco-system/WebSocket/WebSocketExports.cpp
    src/eco-system/WebSocket/WsChannel.cpp
    src/eco-system/WebSocket/WsDeflate.cpp
    src/eco-system/WebSocket/WsEvents.cpp
    src/eco-system/WebSocket/WsFrame.cpp
    src/eco-system/WebSocket/WsHandshake.cpp
    src/eco-system/WebSocket/WsManager.cpp
    src/eco-system/WebSocket/WsProtocol.cpp
    src/eco-system/WebSocket/WsTables.cpp)
target_link_libraries(EcoSystem_WebSocket PUBLIC EcoSystem_Socket EcoSystem_Tls EcoSystem_Stream)
if(NOT WIN32)
    target_link_libraries(EcoSystem_WebSocket PRIVATE OpenSSL::Crypto)
    # WebSockets over HTTP/2 (RFC 8441, §3.9, WS9): the client's nghttp2
    # session. The nghttp2 objects (declared with EcoSystem_HttpServer above)
    # live in this archive, for Http.Server's Http2.cpp too.
    target_sources(EcoSystem_WebSocket PRIVATE $<TARGET_OBJECTS:nghttp2_objects>)
    target_include_directories(EcoSystem_WebSocket PRIVATE
        ${ECO_NGHTTP2_GEN_DIR}
        ${nghttp2_SOURCE_DIR}/lib/includes)
    target_compile_definitions(EcoSystem_WebSocket PRIVATE NGHTTP2_STATICLIB)
    add_dependencies(EcoSystem_WebSocket nghttp2_objects)
endif()

# Every module listed in ECO_SYSTEM_MODS must have a target here.
foreach(mod ${ECO_SYSTEM_MODS})
    if(NOT TARGET EcoSystem_${mod})
        message(FATAL_ERROR "eco-system: ECO_SYSTEM_MODS lists ${mod} but EcoSystem_${mod} is not defined")
    endif()
endforeach()

#------------------------------------------------------------------------------
# Combined convenience library
#------------------------------------------------------------------------------

add_library(EcoSystem INTERFACE)
foreach(mod ${ECO_SYSTEM_MODS})
    target_link_libraries(EcoSystem INTERFACE EcoSystem_${mod})
endforeach()

#------------------------------------------------------------------------------
# Unit tests for EcoSystem_Core (plans/eco-system-library.md Phase 2 step 2.8).
# No Elm program; links the runtime for the Scheduler and the heap.
#   cmake --build <dir> --target eco-system-core-test
#   <dir>/system-kernel-cpp/eco-system-core-test
#------------------------------------------------------------------------------

if(NOT WIN32 AND TARGET EcoRuntimeStatic)
    add_executable(eco-system-core-test EXCLUDE_FROM_ALL
        ${CMAKE_CURRENT_SOURCE_DIR}/../test/eco-system-core/EcoSystemCoreTest.cpp)
    target_compile_features(eco-system-core-test PRIVATE cxx_std_20)
    # EcoSystem_HttpServer for the HttpServer checks (serializeH1, listenOn,
    # Http1Protocol on the reactor; WS2). EcoSystem_Socket and
    # EcoSystem_Stream for the WS1 checks (Conn protocols, listener callback
    # mode, mapped stream pairs; plans/eco-system-websockets.md §3.2, §3.3).
    # EcoSystem_WebSocket for the WS4 frame codec and HTTP head checks (§3.6).
    target_link_libraries(eco-system-core-test PRIVATE
        EcoSystem_WebSocket EcoSystem_Tls
        EcoSystem_HttpServer EcoSystem_Socket EcoSystem_Stream EcoSystem_Core
        EcoRuntimeStatic Threads::Threads)
    # The HTTP/2 checks drive Http2Protocol with an nghttp2 client session
    # (the library objects are inside libEcoSystem_WebSocket.a, WS9).
    target_include_directories(eco-system-core-test PRIVATE
        ${ECO_NGHTTP2_GEN_DIR} ${nghttp2_SOURCE_DIR}/lib/includes)
    target_compile_definitions(eco-system-core-test PRIVATE NGHTTP2_STATICLIB)
    if(ECO_ASSERTS_ON)
        target_compile_options(eco-system-core-test PRIVATE -UNDEBUG)
    endif()
endif()
