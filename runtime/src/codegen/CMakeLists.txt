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

# Note: elm-kernel-cpp is included from the top-level CMakeLists.txt
# The ElmKernel target is available for linking.

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

# Generate enum attribute declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoEnums.h.inc -gen-enum-decls)

# Generate enum attribute definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_DIR}/EcoEnums.cpp.inc -gen-enum-defs)

# Create a target that depends on all generated files
add_public_tablegen_target(EcoOpsIncGen)

#------------------------------------------------------------------------------
# Create a library target for the dialect
#------------------------------------------------------------------------------

add_mlir_dialect_library(EcoDialect
    EcoDialect.cpp
    EcoOps.cpp
    EcoTypes.cpp

    PARTIAL_SOURCES_INTENDED

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
# Suppress C++20 ambiguous operator warning from MLIR headers
target_compile_options(obj.EcoDialect PRIVATE -Wno-ambiguous-reversed-operator)

#------------------------------------------------------------------------------
# Generate BF (ByteFusion) dialect from BFOps.td
#------------------------------------------------------------------------------

# Set output directory for bf dialect generated files
set(BF_TABLEGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/include/bf)
file(MAKE_DIRECTORY ${BF_TABLEGEN_OUTPUT_DIR})

set(LLVM_TARGET_DEFINITIONS BF/BFOps.td)

# Generate BF Op class declarations (header file)
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFOps.h.inc -gen-op-decls)

# Generate BF Op class definitions (implementation file)
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFOps.cpp.inc -gen-op-defs)

# Generate BF dialect declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFDialect.h.inc -gen-dialect-decls)

# Generate BF dialect definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFDialect.cpp.inc -gen-dialect-defs)

# Generate BF type declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFTypes.h.inc -gen-typedef-decls)

# Generate BF type definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFTypes.cpp.inc -gen-typedef-defs)

# Generate BF enum attribute declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFEnums.h.inc -gen-enum-decls)

# Generate BF enum attribute definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_DIR}/BFEnums.cpp.inc -gen-enum-defs)

# Create a target that depends on all generated BF files
add_public_tablegen_target(BFOpsIncGen)

#------------------------------------------------------------------------------
# Create BF dialect library
#------------------------------------------------------------------------------

add_mlir_dialect_library(BFDialect
    BF/BFDialect.cpp
    BF/BFOps.cpp
    BF/BFTypes.cpp

    PARTIAL_SOURCES_INTENDED

    ADDITIONAL_HEADER_DIRS
    ${CMAKE_CURRENT_BINARY_DIR}/include/bf

    DEPENDS
    BFOpsIncGen

    LINK_LIBS PUBLIC
    MLIRIR
    MLIRSupport
    MLIRSideEffectInterfaces
)

# Include directory for BF source headers
target_include_directories(obj.BFDialect PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/BF)

target_compile_features(obj.BFDialect PRIVATE cxx_std_17)
target_compile_options(obj.BFDialect PRIVATE -Wno-ambiguous-reversed-operator)

#------------------------------------------------------------------------------
# Create a library for Eco passes
#------------------------------------------------------------------------------

add_mlir_library(EcoPasses
    Passes/RCElimination.cpp
    Passes/JoinpointNormalization.cpp
    Passes/EcoControlFlowToSCF.cpp
    Passes/UndefinedFunction.cpp
    # EcoToLLVM modular pass files
    Passes/EcoToLLVM.cpp
    Passes/EcoToLLVMRuntime.cpp
    Passes/EcoToLLVMTypes.cpp
    Passes/EcoToLLVMHeap.cpp
    Passes/EcoToLLVMClosures.cpp
    Passes/EcoToLLVMControlFlow.cpp
    Passes/EcoToLLVMArith.cpp
    Passes/EcoToLLVMGlobals.cpp
    Passes/EcoToLLVMErrorDebug.cpp
    Passes/EcoToLLVMFunc.cpp
    # BF (ByteFusion) dialect lowering
    Passes/BFToLLVM.cpp

    PARTIAL_SOURCES_INTENDED

    ADDITIONAL_HEADER_DIRS
    ${CMAKE_CURRENT_BINARY_DIR}/include/eco
    ${CMAKE_CURRENT_BINARY_DIR}/include/bf

    DEPENDS
    EcoOpsIncGen
    BFOpsIncGen

    LINK_LIBS PUBLIC
    EcoDialect
    BFDialect
    MLIRIR
    MLIRSupport
    MLIRPass
    MLIRTransforms
    MLIRFuncDialect
    MLIRArithDialect
    MLIRControlFlowDialect
    MLIRSCFDialect
    MLIRLLVMDialect
    MLIRLLVMCommonConversion
    MLIRFuncToLLVM
    MLIRArithToLLVM
    MLIRControlFlowToLLVM
    MLIRSCFToControlFlow
    MLIRReconcileUnrealizedCasts
)

target_compile_features(obj.EcoPasses PRIVATE cxx_std_17)
target_compile_options(obj.EcoPasses PRIVATE -Wno-ambiguous-reversed-operator)

#------------------------------------------------------------------------------
# Build the ecogen executable (legacy, for parsing only)
#------------------------------------------------------------------------------

add_llvm_executable(ecogen
    ../ecogen.cpp
    PARTIAL_SOURCES_INTENDED
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
target_compile_options(ecogen PRIVATE -Wno-ambiguous-reversed-operator)

#------------------------------------------------------------------------------
# Build the ecoc executable (full compiler with lowering and JIT)
#------------------------------------------------------------------------------

add_llvm_executable(ecoc
    ecoc.cpp
    EcoPipeline.cpp
    RuntimeSymbols.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    PARTIAL_SOURCES_INTENDED
)

target_include_directories(ecoc PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_BINARY_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
)

target_link_libraries(ecoc PRIVATE
    EcoDialect
    BFDialect
    EcoPasses
    ElmKernel
    MLIRIR
    MLIRParser
    MLIRPass
    MLIRSupport
    MLIRTransforms
    MLIRFuncDialect
    MLIRFuncAllExtensions
    MLIRArithDialect
    MLIRControlFlowDialect
    MLIRSCFDialect
    MLIRLLVMDialect
    MLIRLLVMCommonConversion
    MLIRFuncToLLVM
    MLIRArithToLLVM
    MLIRControlFlowToLLVM
    MLIRSCFToControlFlow
    MLIRReconcileUnrealizedCasts
    MLIRExecutionEngine
    MLIRTargetLLVMIRExport
    MLIRBuiltinToLLVMIRTranslation
    MLIRLLVMToLLVMIRTranslation
    LLVMSupport
    LLVMCore
    LLVMOrcJIT
)

target_compile_features(ecoc PRIVATE cxx_std_20)
target_compile_options(ecoc PRIVATE -Wno-ambiguous-reversed-operator)

# The runtime code uses exceptions, so we need to enable them
# (LLVM/MLIR disables exceptions by default)
target_compile_options(ecoc PRIVATE -fexceptions)

# Need pthreads for the runtime
find_package(Threads REQUIRED)
target_link_libraries(ecoc PRIVATE Threads::Threads)

#------------------------------------------------------------------------------
# Build the EcoRunner library (for in-process test execution)
#------------------------------------------------------------------------------

add_mlir_library(EcoRunner
    EcoRunner.cpp
    EcoPipeline.cpp
    RuntimeSymbols.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    PARTIAL_SOURCES_INTENDED

    ADDITIONAL_HEADER_DIRS
    ${CMAKE_CURRENT_BINARY_DIR}/include/eco
    ${CMAKE_CURRENT_BINARY_DIR}/include/bf

    DEPENDS
    EcoOpsIncGen
    BFOpsIncGen

    LINK_LIBS PUBLIC
    EcoDialect
    BFDialect
    EcoPasses
    ElmKernel
    MLIRIR
    MLIRParser
    MLIRPass
    MLIRSupport
    MLIRTransforms
    MLIRFuncDialect
    MLIRFuncAllExtensions
    MLIRArithDialect
    MLIRControlFlowDialect
    MLIRSCFDialect
    MLIRLLVMDialect
    MLIRLLVMCommonConversion
    MLIRFuncToLLVM
    MLIRArithToLLVM
    MLIRControlFlowToLLVM
    MLIRSCFToControlFlow
    MLIRReconcileUnrealizedCasts
    MLIRExecutionEngine
    MLIRTargetLLVMIRExport
    MLIRBuiltinToLLVMIRTranslation
    MLIRLLVMToLLVMIRTranslation
    LLVMSupport
    LLVMCore
    LLVMOrcJIT
)

target_include_directories(obj.EcoRunner PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
    ${CMAKE_CURRENT_SOURCE_DIR}/BF
)

target_compile_features(obj.EcoRunner PRIVATE cxx_std_20)
target_compile_options(obj.EcoRunner PRIVATE -Wno-ambiguous-reversed-operator -fexceptions)
target_link_libraries(obj.EcoRunner PRIVATE Threads::Threads)

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
