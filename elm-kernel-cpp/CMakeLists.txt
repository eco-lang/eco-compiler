cmake_minimum_required(VERSION 3.16)
project(elm-kernel LANGUAGES CXX)

# Elm Kernel C++ Implementation
# Provides kernel functions with C-linkage exports for LLVM JIT

# Runtime include directory (for allocator headers)
set(RUNTIME_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../runtime/src)

#------------------------------------------------------------------------------
# Per-module static libraries
#------------------------------------------------------------------------------

# Basics module
add_library(ElmKernel_Basics STATIC
    src/core/Basics.cpp
    src/core/BasicsExports.cpp
)
target_include_directories(ElmKernel_Basics PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Basics PUBLIC cxx_std_20)

# Bitwise module
add_library(ElmKernel_Bitwise STATIC
    src/core/Bitwise.cpp
    src/core/BitwiseExports.cpp
)
target_include_directories(ElmKernel_Bitwise PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Bitwise PUBLIC cxx_std_20)

# Char module
add_library(ElmKernel_Char STATIC
    src/core/Char.cpp
    src/core/CharExports.cpp
)
target_include_directories(ElmKernel_Char PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Char PUBLIC cxx_std_20)

# String module
add_library(ElmKernel_String STATIC
    src/core/String.cpp
    src/core/StringExports.cpp
)
target_include_directories(ElmKernel_String PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_String PUBLIC cxx_std_20)

# List module
add_library(ElmKernel_List STATIC
    src/core/List.cpp
    src/core/ListExports.cpp
)
target_include_directories(ElmKernel_List PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_List PUBLIC cxx_std_20)

# Utils module
add_library(ElmKernel_Utils STATIC
    src/core/Utils.cpp
    src/core/UtilsExports.cpp
)
target_include_directories(ElmKernel_Utils PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Utils PUBLIC cxx_std_20)

# JsArray module
add_library(ElmKernel_JsArray STATIC
    src/core/JsArray.cpp
    src/core/JsArrayExports.cpp
)
target_include_directories(ElmKernel_JsArray PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_JsArray PUBLIC cxx_std_20)

# Debug module
add_library(ElmKernel_Debug STATIC
    src/core/Debug.cpp
    src/core/DebugExports.cpp
)
target_include_directories(ElmKernel_Debug PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Debug PUBLIC cxx_std_20)

# Scheduler module
add_library(ElmKernel_Scheduler STATIC
    src/core/Scheduler.cpp
    src/core/SchedulerExports.cpp
)
target_include_directories(ElmKernel_Scheduler PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Scheduler PUBLIC cxx_std_20)

# Platform module (no exports yet - stubs)
add_library(ElmKernel_Platform STATIC
    src/core/Platform.cpp
)
target_include_directories(ElmKernel_Platform PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Platform PUBLIC cxx_std_20)

# Process module (no exports yet - stubs)
add_library(ElmKernel_Process STATIC
    src/core/Process.cpp
)
target_include_directories(ElmKernel_Process PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Process PUBLIC cxx_std_20)

# Debugger module (no exports yet - stubs)
add_library(ElmKernel_Debugger STATIC
    src/core/Debugger.cpp
)
target_include_directories(ElmKernel_Debugger PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Debugger PUBLIC cxx_std_20)

# VirtualDom module
add_library(ElmKernel_VirtualDom STATIC
    src/virtual-dom/VirtualDom.cpp
    src/virtual-dom/VirtualDomExports.cpp
)
target_include_directories(ElmKernel_VirtualDom PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_VirtualDom PUBLIC cxx_std_20)

# Json module (no exports yet - complex types)
add_library(ElmKernel_Json STATIC
    src/json/Json.cpp
)
target_include_directories(ElmKernel_Json PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Json PUBLIC cxx_std_20)

# Browser module (no exports yet - stubs)
add_library(ElmKernel_Browser STATIC
    src/browser/Browser.cpp
)
target_include_directories(ElmKernel_Browser PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Browser PUBLIC cxx_std_20)

# Bytes module (no exports yet)
add_library(ElmKernel_Bytes STATIC
    src/bytes/Bytes.cpp
)
target_include_directories(ElmKernel_Bytes PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Bytes PUBLIC cxx_std_20)

# File module (no exports yet - stubs)
add_library(ElmKernel_File STATIC
    src/file/File.cpp
)
target_include_directories(ElmKernel_File PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_File PUBLIC cxx_std_20)

# Http module (no exports yet - stubs)
add_library(ElmKernel_Http STATIC
    src/http/Http.cpp
)
target_include_directories(ElmKernel_Http PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Http PUBLIC cxx_std_20)

# Parser module (no exports yet)
add_library(ElmKernel_Parser STATIC
    src/parser/Parser.cpp
)
target_include_directories(ElmKernel_Parser PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Parser PUBLIC cxx_std_20)

# Regex module (no exports yet - stubs)
add_library(ElmKernel_Regex STATIC
    src/regex/Regex.cpp
)
target_include_directories(ElmKernel_Regex PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Regex PUBLIC cxx_std_20)

# Time module (no exports yet)
add_library(ElmKernel_Time STATIC
    src/time/Time.cpp
)
target_include_directories(ElmKernel_Time PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Time PUBLIC cxx_std_20)

# Url module (no exports yet)
add_library(ElmKernel_Url STATIC
    src/url/Url.cpp
)
target_include_directories(ElmKernel_Url PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${RUNTIME_INCLUDE_DIR}
)
target_compile_features(ElmKernel_Url PUBLIC cxx_std_20)

#------------------------------------------------------------------------------
# Combined convenience library
#------------------------------------------------------------------------------

add_library(ElmKernel INTERFACE)
target_link_libraries(ElmKernel INTERFACE
    ElmKernel_Basics
    ElmKernel_Bitwise
    ElmKernel_Char
    ElmKernel_String
    ElmKernel_List
    ElmKernel_Utils
    ElmKernel_JsArray
    ElmKernel_Debug
    ElmKernel_Scheduler
    ElmKernel_Platform
    ElmKernel_Process
    ElmKernel_Debugger
    ElmKernel_VirtualDom
    ElmKernel_Json
    ElmKernel_Browser
    ElmKernel_Bytes
    ElmKernel_File
    ElmKernel_Http
    ElmKernel_Parser
    ElmKernel_Regex
    ElmKernel_Time
    ElmKernel_Url
)

# Keep asserts enabled even in release builds
foreach(target
    ElmKernel_Basics ElmKernel_Bitwise ElmKernel_Char ElmKernel_String
    ElmKernel_List ElmKernel_Utils ElmKernel_JsArray ElmKernel_Debug
    ElmKernel_Scheduler ElmKernel_Platform ElmKernel_Process ElmKernel_Debugger
    ElmKernel_VirtualDom ElmKernel_Json ElmKernel_Browser ElmKernel_Bytes
    ElmKernel_File ElmKernel_Http ElmKernel_Parser ElmKernel_Regex
    ElmKernel_Time ElmKernel_Url
)
    target_compile_options(${target} PRIVATE -UNDEBUG)
endforeach()
