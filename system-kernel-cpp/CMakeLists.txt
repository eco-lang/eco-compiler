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
    src/eco-system/Core/SignalService.cpp)
eco_system_module(Core         POSIX ${ECO_SYSTEM_CORE_SRCS})
find_package(Threads REQUIRED)
target_link_libraries(EcoSystem_Core PUBLIC Threads::Threads)
eco_system_module(System       POSIX src/eco-system/System/System.cpp)
eco_system_module(Stream       POSIX src/eco-system/Stream/Stream.cpp)
eco_system_module(FileSystem   POSIX src/eco-system/FileSystem/FileSystem.cpp)
eco_system_module(ChildProcess POSIX src/eco-system/ChildProcess/ChildProcess.cpp)
eco_system_module(Terminal     POSIX src/eco-system/Terminal/Terminal.cpp)
eco_system_module(HttpServer   POSIX src/eco-system/HttpServer/HttpServer.cpp)
eco_system_module(HttpStream   POSIX src/eco-system/HttpStream/HttpStream.cpp)

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
    target_link_libraries(eco-system-core-test PRIVATE
        EcoSystem_Core EcoRuntimeStatic Threads::Threads)
    if(ECO_ASSERTS_ON)
        target_compile_options(eco-system-core-test PRIVATE -UNDEBUG)
    endif()
endif()
