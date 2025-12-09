# CMakeLists.txt for Eco MLIR dialect code generation
#
# This uses MLIR's TableGen infrastructure to generate C++ code from .td files.
#
# Prerequisites:
#   - LLVM/MLIR must be installed (e.g., via apt install llvm-18-dev mlir-18-dev)
#   - Or built from source with MLIR enabled
#
# The generated files will be placed in the build directory under:
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/

# Find MLIR package (this also finds LLVM)
find_package(MLIR REQUIRED CONFIG)

message(STATUS "Using MLIRConfig.cmake in: ${MLIR_DIR}")
message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")

# Add MLIR and LLVM CMake modules to the module path
list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")

# Include MLIR and LLVM CMake utilities
include(TableGen)
include(AddLLVM)
include(AddMLIR)
include(HandleLLVMOptions)

# Include directories for MLIR/LLVM headers
include_directories(${LLVM_INCLUDE_DIRS})
include_directories(${MLIR_INCLUDE_DIRS})

# Include directory for generated headers
include_directories(${CMAKE_CURRENT_BINARY_DIR}/include)

# Include directory for source headers (EcoDialect.h, EcoOps.h)
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# Add LLVM definitions
add_definitions(${LLVM_DEFINITIONS})

# Set the output directory for generated TableGen files
set(MLIR_TABLEGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/include/eco)
file(MAKE_DIRECTORY ${MLIR_TABLEGEN_OUTPUT_DIR})

# Include the directory containing our .td files
set(MLIR_TABLEGEN_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR})

#------------------------------------------------------------------------------
# Generate Op declarations and definitions from Ops.td
#------------------------------------------------------------------------------

set(LLVM_TARGET_DEFINITIONS Ops.td)

# Generate Op class declarations (header file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOps.h.inc -gen-op-decls)

# Generate Op class definitions (implementation file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOps.cpp.inc -gen-op-defs)

# Generate dialect declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoDialect.h.inc -gen-dialect-decls)

# Generate dialect definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoDialect.cpp.inc -gen-dialect-defs)

# Generate type declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoTypes.h.inc -gen-typedef-decls)

# Generate type definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoTypes.cpp.inc -gen-typedef-defs)

# Create a target that depends on all generated files
add_public_tablegen_target(EcoOpsIncGen)

#------------------------------------------------------------------------------
# Create a library target for the dialect
#------------------------------------------------------------------------------

add_mlir_dialect_library(EcoDialect
    EcoDialect.cpp
    EcoOps.cpp
    EcoTypes.cpp

    ADDITIONAL_HEADER_DIRS
    ${CMAKE_CURRENT_BINARY_DIR}/include/eco

    DEPENDS
    EcoOpsIncGen

    LINK_LIBS PUBLIC
    MLIRIR
    MLIRSupport
    MLIRControlFlowInterfaces
    MLIRSideEffectInterfaces
)

# LLVM/MLIR headers require C++17 features
target_compile_features(obj.EcoDialect PRIVATE cxx_std_17)

#------------------------------------------------------------------------------
# Build the ecogen executable
#------------------------------------------------------------------------------

add_llvm_executable(ecogen
    ../ecogen.cpp
)

target_include_directories(ecogen PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_BINARY_DIR}/include
)

target_link_libraries(ecogen PRIVATE
    EcoDialect
    MLIRIR
    MLIRParser
    MLIRSupport
    MLIRFuncDialect
    LLVMSupport
)

target_compile_features(ecogen PRIVATE cxx_std_17)

#------------------------------------------------------------------------------
# Usage instructions
#------------------------------------------------------------------------------
#
# After building, the following files will be generated:
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoOps.h.inc
#     - Op class declarations (include in your EcoOps.h)
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoOps.cpp.inc
#     - Op class definitions (include in your EcoOps.cpp)
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoDialect.h.inc
#     - Dialect declarations (include in your EcoDialect.h)
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoDialect.cpp.inc
#     - Dialect definitions (include in your EcoDialect.cpp)
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoTypes.h.inc
#     - Type declarations (include in your EcoTypes.h)
#
#   ${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoTypes.cpp.inc
#     - Type definitions (include in your EcoTypes.cpp)
#
# To use in your C++ code:
#
#   // EcoDialect.h
#   #include "mlir/IR/Dialect.h"
#   #include "eco/EcoDialect.h.inc"
#
#   // EcoTypes.h
#   #include "mlir/IR/Types.h"
#   #define GET_TYPEDEF_CLASSES
#   #include "eco/EcoTypes.h.inc"
#
#   // EcoOps.h
#   #include "mlir/IR/OpDefinition.h"
#   #define GET_OP_CLASSES
#   #include "eco/EcoOps.h.inc"
#
#   // EcoDialect.cpp
#   #include "eco/EcoDialect.cpp.inc"
#   void EcoDialect::initialize() {
#     addTypes<
#     #define GET_TYPEDEF_LIST
#     #include "eco/EcoTypes.cpp.inc"
#     >();
#     addOperations<
#     #define GET_OP_LIST
#     #include "eco/EcoOps.cpp.inc"
#     >();
#   }
#
#   // EcoOps.cpp
#   #define GET_OP_CLASSES
#   #include "eco/EcoOps.cpp.inc"
#
#   // EcoTypes.cpp
#   #define GET_TYPEDEF_CLASSES
#   #include "eco/EcoTypes.cpp.inc"
#
