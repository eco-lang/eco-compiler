cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES CXX)

# ============================================================
# 1) Find MLIR / LLVM (once globally)
# ============================================================
find_package(MLIR REQUIRED CONFIG)

# Make MLIR/LLVM CMake modules (TableGen helpers) visible everywhere
# Prefer the exported *_CMAKE_DIR vars if present; fall back to *_DIR.
if (DEFINED MLIR_CMAKE_DIR)
    list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
else ()
    list(APPEND CMAKE_MODULE_PATH "${MLIR_DIR}")
endif ()

if (DEFINED LLVM_CMAKE_DIR)
    list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
else ()
    list(APPEND CMAKE_MODULE_PATH "${LLVM_DIR}")
endif ()

include(AddLLVM)
include(AddMLIR)

# ============================================================
# 2) Shared configuration target (inherits common settings)
# ============================================================
add_library(toy_common INTERFACE)

# Require C++20
target_compile_features(toy_common INTERFACE cxx_std_20)

# Disable warnings (only show errors)
if (MSVC)
    target_compile_options(toy_common INTERFACE /w)
else ()
    target_compile_options(toy_common INTERFACE -w)
endif ()

# Prefer lld when using Clang
if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_link_options(toy_common INTERFACE -fuse-ld=lld)
endif ()

# Link minimal MLIR pieces every chapter needs
target_link_libraries(toy_common INTERFACE
        MLIRIR
        MLIRSupport
)

# Include MLIR/LLVM directories (INTERFACE = inherited by dependents)
target_include_directories(toy_common INTERFACE
        ${MLIR_INCLUDE_DIRS}
        ${LLVM_INCLUDE_DIRS}
)

# ============================================================
# 3) Helper function: add_toy_chapter(NAME <name> SOURCES ... [LIBS ...])
# ============================================================
# 3) Helper function: add_toy_chapter(NAME <name> SOURCES ... [LIBS ...])
add_custom_target(Toy)
set_target_properties(Toy PROPERTIES FOLDER "MLIR/Examples")

macro(add_toy_chapter name)
    add_dependencies(Toy ${name})
    set(options)
    set(oneValueArgs)
    set(multiValueArgs SOURCES LIBS DEPENDS)
    cmake_parse_arguments(CHAP "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    add_executable(${name} ${CHAP_SOURCES})
    if (CHAP_DEPENDS)
        add_dependencies(${name} ${CHAP_DEPENDS})
    endif ()
    if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/include")
        target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
    endif ()
    target_include_directories(${name} PRIVATE
            "${CMAKE_CURRENT_BINARY_DIR}"
            "${CMAKE_CURRENT_BINARY_DIR}/include"
    )
    target_link_libraries(${name} PRIVATE toy_common ${CHAP_LIBS})
endmacro()

# ============================================================
# 4) Add all chapters
# ============================================================
add_subdirectory(chapter1)
add_subdirectory(chapter2)
