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

# GC debug assertions: default ON for Debug builds, OFF for Release.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" ON)
else()
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" OFF)
endif()

option(ECO_LOWERING_VALIDATION "Enable validation-only lowering passes (GC liveness audit, post-RS4GC ptr<1>↔i64 boundary verifier; slow, independent of ECO_GC_DEBUG)" OFF)

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

# Set the output directory for generated TableGen files. The relative
# subdirectory is what `mlir_tablegen()` accepts — it always prepends
# `${CMAKE_CURRENT_BINARY_DIR}` to its argument, so passing an absolute
# path produces a malformed `<binary_dir>/<absolute_path>` output target
# in the ninja graph (consumers ask for `<binary_dir>/include/eco/...`,
# can't find a rule, and `make full` fails after `clean`). The absolute
# variant below is used elsewhere (OBJECT_DEPENDS, ADDITIONAL_HEADER_DIRS).
set(MLIR_TABLEGEN_OUTPUT_SUBDIR include/eco)
set(MLIR_TABLEGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/${MLIR_TABLEGEN_OUTPUT_SUBDIR})
file(MAKE_DIRECTORY ${MLIR_TABLEGEN_OUTPUT_DIR})

# Include the directory containing our .td files
set(MLIR_TABLEGEN_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR})

#------------------------------------------------------------------------------
# Generate Op declarations and definitions from Ops.td
#------------------------------------------------------------------------------

set(LLVM_TARGET_DEFINITIONS Ops.td)

# Generate Op class declarations (header file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoOps.h.inc -gen-op-decls)

# Generate Op class definitions (implementation file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoOps.cpp.inc -gen-op-defs)

# Generate OpInterface declarations (header file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoOpInterfaces.h.inc -gen-op-interface-decls)

# Generate OpInterface definitions (implementation file)
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoOpInterfaces.cpp.inc -gen-op-interface-defs)

# Generate dialect declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoDialect.h.inc -gen-dialect-decls)

# Generate dialect definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoDialect.cpp.inc -gen-dialect-defs)

# Generate type declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoTypes.h.inc -gen-typedef-decls)

# Generate type definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoTypes.cpp.inc -gen-typedef-defs)

# Generate enum attribute declarations
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoEnums.h.inc -gen-enum-decls)

# Generate enum attribute definitions
mlir_tablegen(${MLIR_TABLEGEN_OUTPUT_SUBDIR}/EcoEnums.cpp.inc -gen-enum-defs)

# Create a target that depends on all generated files
add_public_tablegen_target(EcoOpsIncGen)

# Concrete list of generated tablegen outputs that the dialect/passes #include.
# Used as explicit OBJECT_DEPENDS so ninja rebuilds the .o files whenever the
# generated headers change, even if a stale depfile from a previous configure
# cycle would otherwise hide the dep.
set(ECO_TABLEGEN_OUTPUTS
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOps.h.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOps.cpp.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOpInterfaces.h.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoOpInterfaces.cpp.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoDialect.h.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoDialect.cpp.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoTypes.h.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoTypes.cpp.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoEnums.h.inc
    ${MLIR_TABLEGEN_OUTPUT_DIR}/EcoEnums.cpp.inc
)

set_source_files_properties(
    EcoDialect.cpp EcoOps.cpp EcoTypes.cpp
    PROPERTIES OBJECT_DEPENDS "${ECO_TABLEGEN_OUTPUTS}"
)

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

# Set output directory for bf dialect generated files. The relative
# subdir is what we pass to `mlir_tablegen()` (which prepends
# `${CMAKE_CURRENT_BINARY_DIR}`); the absolute variant is used by
# OBJECT_DEPENDS / ADDITIONAL_HEADER_DIRS callers below.
set(BF_TABLEGEN_OUTPUT_SUBDIR include/bf)
set(BF_TABLEGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/${BF_TABLEGEN_OUTPUT_SUBDIR})
file(MAKE_DIRECTORY ${BF_TABLEGEN_OUTPUT_DIR})

set(LLVM_TARGET_DEFINITIONS BF/BFOps.td)

# Generate BF Op class declarations (header file)
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFOps.h.inc -gen-op-decls)

# Generate BF Op class definitions (implementation file)
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFOps.cpp.inc -gen-op-defs)

# Generate BF dialect declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFDialect.h.inc -gen-dialect-decls)

# Generate BF dialect definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFDialect.cpp.inc -gen-dialect-defs)

# Generate BF type declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFTypes.h.inc -gen-typedef-decls)

# Generate BF type definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFTypes.cpp.inc -gen-typedef-defs)

# Generate BF enum attribute declarations
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFEnums.h.inc -gen-enum-decls)

# Generate BF enum attribute definitions
mlir_tablegen(${BF_TABLEGEN_OUTPUT_SUBDIR}/BFEnums.cpp.inc -gen-enum-defs)

# Create a target that depends on all generated BF files
add_public_tablegen_target(BFOpsIncGen)

set(BF_TABLEGEN_OUTPUTS
    ${BF_TABLEGEN_OUTPUT_DIR}/BFOps.h.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFOps.cpp.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFDialect.h.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFDialect.cpp.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFTypes.h.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFTypes.cpp.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFEnums.h.inc
    ${BF_TABLEGEN_OUTPUT_DIR}/BFEnums.cpp.inc
)

set_source_files_properties(
    BF/BFDialect.cpp BF/BFOps.cpp BF/BFTypes.cpp
    PROPERTIES OBJECT_DEPENDS "${BF_TABLEGEN_OUTPUTS}"
)

# All EcoPasses sources transitively include EcoOps.cpp.inc / EcoOps.h.inc via
# EcoDialect.h, and the EcoToLLVM* sources also pull in BF op headers. Re-declaring
# the dependency explicitly guards against stale ninja depfiles after .td edits.
set_source_files_properties(
    Passes/RCElimination.cpp
    Passes/EcoPAPSimplify.cpp
    Passes/EcoEscapeAnalysis.cpp
    Passes/EcoUnboxedAggSpecialize.cpp
    Passes/EcoUnboxedAggCrossSpec.cpp
    Passes/EcoFlattenAggBoundary.cpp
    Passes/JoinpointNormalization.cpp
    Passes/EcoControlFlowToSCF.cpp
    Passes/UndefinedFunction.cpp
    Passes/CheckEcoClosureCaptures.cpp
    Passes/EcoBoxAggregateOperands.cpp
    Passes/EcoGCPrepare.cpp
    Passes/EcoGCLivenessAudit.cpp
    Passes/EcoToLLVM.cpp
    Passes/EcoToLLVMRuntime.cpp
    Passes/EcoToLLVMTypes.cpp
    Passes/EcoToLLVMHeap.cpp
    Passes/EcoToLLVMValueAgg.cpp
    Passes/EcoToLLVMClosures.cpp
    Passes/EcoToLLVMControlFlow.cpp
    Passes/EcoToLLVMArith.cpp
    Passes/EcoToLLVMGlobals.cpp
    Passes/EcoToLLVMErrorDebug.cpp
    Passes/EcoToLLVMFunc.cpp
    Passes/EcoGCStrategy.cpp
    Passes/EcoPtrIntVerify.cpp
    Passes/EcoBoxedStoreVerify.cpp
    Passes/BFToLLVM.cpp
    PROPERTIES OBJECT_DEPENDS "${ECO_TABLEGEN_OUTPUTS};${BF_TABLEGEN_OUTPUTS}"
)

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
    Passes/EcoPAPSimplify.cpp
    # Phase 1 escape analysis + specialise (Stage 1 Eco->Eco; gated
    # behind -enable-unboxed-agg)
    Passes/EcoEscapeAnalysis.cpp
    Passes/EcoUnboxedAggSpecialize.cpp
    Passes/EcoUnboxedAggCrossSpec.cpp
    Passes/EcoFlattenAggBoundary.cpp
    Passes/JoinpointNormalization.cpp
    Passes/EcoControlFlowToSCF.cpp
    Passes/UndefinedFunction.cpp
    Passes/CheckEcoClosureCaptures.cpp
    # Phase 1 of widen-construct-make-call-aggregates: box aggregate operands
    Passes/EcoBoxAggregateOperands.cpp
    # GC preparation pass (root sets, allocation grouping)
    Passes/EcoGCPrepare.cpp
    # GC liveness audit (debug-only verification)
    Passes/EcoGCLivenessAudit.cpp
    # EcoToLLVM modular pass files
    Passes/EcoToLLVM.cpp
    Passes/EcoToLLVMRuntime.cpp
    Passes/EcoToLLVMTypes.cpp
    Passes/EcoToLLVMHeap.cpp
    # Phase 0 escape-analysis plumbing — value-level aggregates
    Passes/EcoToLLVMValueAgg.cpp
    Passes/EcoToLLVMClosures.cpp
    Passes/EcoToLLVMControlFlow.cpp
    Passes/EcoToLLVMArith.cpp
    Passes/EcoToLLVMGlobals.cpp
    Passes/EcoToLLVMErrorDebug.cpp
    Passes/EcoToLLVMFunc.cpp
    # GC strategy registration + post-MLIR LLVM IR passes
    Passes/EcoGCStrategy.cpp
    # Post-RS4GC ptr<1>↔i64 boundary verifier (gated by ECO_LOWERING_VALIDATION)
    Passes/EcoPtrIntVerify.cpp
    # Pre-store stale-HPointer barrier on direct boxed-slot stores (gated by ECO_LOWERING_VALIDATION)
    Passes/EcoBoxedStoreVerify.cpp
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
    MLIRAnalysis
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
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(obj.EcoPasses PRIVATE ECO_LOWERING_VALIDATION=1)
endif()

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
    EcoBackend.cpp
    EcoPipeline.cpp
    RuntimeSymbols.cpp
    ../jit/EcoJIT.cpp
    ../allocator/StackMap.cpp
    ../allocator/StackUnwind.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    ../platform/Scheduler.cpp
    ../platform/TimerService.cpp
    ../platform/PlatformRuntime.cpp
    PARTIAL_SOURCES_INTENDED
)

target_include_directories(ecoc PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../jit
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
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(ecoc PRIVATE ECO_LOWERING_VALIDATION=1)
endif()

# Need pthreads for the runtime
find_package(Threads REQUIRED)
target_link_libraries(ecoc PRIVATE Threads::Threads)

# libunwind for stack unwinding in GC root scanning — LLVM's libunwind,
# located via cmake/LLVMLibunwind.cmake from the top-level CMakeLists.
target_link_libraries(ecoc PRIVATE eco::llvm_libunwind)

#------------------------------------------------------------------------------
# Build the EcoRunner library (for in-process test execution)
#------------------------------------------------------------------------------

add_mlir_library(EcoRunner
    EcoRunner.cpp
    EcoBackend.cpp
    EcoPipeline.cpp
    RuntimeSymbols.cpp
    ../jit/EcoJIT.cpp
    ../allocator/StackMap.cpp
    ../allocator/StackUnwind.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    ../platform/Scheduler.cpp
    ../platform/TimerService.cpp
    ../platform/PlatformRuntime.cpp
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
    ${CMAKE_CURRENT_SOURCE_DIR}/../jit
    ${CMAKE_CURRENT_SOURCE_DIR}/BF
)

target_compile_features(obj.EcoRunner PRIVATE cxx_std_20)
target_compile_options(obj.EcoRunner PRIVATE -Wno-ambiguous-reversed-operator -fexceptions)
if(ECO_GC_DEBUG)
    target_compile_definitions(obj.EcoRunner PRIVATE ECO_GC_DEBUG=1)
endif()
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(obj.EcoRunner PRIVATE ECO_LOWERING_VALIDATION=1)
endif()
target_link_libraries(obj.EcoRunner PRIVATE Threads::Threads)
# PUBLIC so that test/stress-test, which link against EcoRunner, transitively
# get LLVM libunwind's include dir, library, and rpath flag.
target_link_libraries(EcoRunner PUBLIC eco::llvm_libunwind)

#------------------------------------------------------------------------------
# Build the EcoRuntimeStatic library (for linking into AOT-compiled binaries)
#------------------------------------------------------------------------------

add_library(EcoRuntimeStatic STATIC
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StackMap.cpp
    ../allocator/StackUnwind.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    ../platform/Scheduler.cpp
    ../platform/TimerService.cpp
    ../platform/PlatformRuntime.cpp
)

target_include_directories(EcoRuntimeStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
)

target_compile_features(EcoRuntimeStatic PRIVATE cxx_std_20)
target_compile_options(EcoRuntimeStatic PRIVATE -fexceptions -UNDEBUG)

# PUBLIC so AOT consumers inherit LLVM libunwind's include dir, library, and
# rpath flag. See cmake/LLVMLibunwind.cmake.
target_link_libraries(EcoRuntimeStatic PUBLIC eco::llvm_libunwind)

if(ECO_GC_DEBUG)
    target_compile_definitions(EcoRuntimeStatic PRIVATE ECO_GC_DEBUG=1)
endif()

#------------------------------------------------------------------------------
# Build the EcoEntryStatic library (main() wrapper for AOT-compiled binaries)
#------------------------------------------------------------------------------

add_library(EcoEntryStatic STATIC
    eco_entry.cpp
    eco_native_stub.cpp
)

target_include_directories(EcoEntryStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
)

target_compile_features(EcoEntryStatic PRIVATE cxx_std_20)
target_compile_options(EcoEntryStatic PRIVATE -fexceptions -UNDEBUG)
if(ECO_GC_DEBUG)
    target_compile_definitions(EcoEntryStatic PRIVATE ECO_GC_DEBUG=1)
endif()

#------------------------------------------------------------------------------
# EcoNativeDriverStatic library — extracted MLIR -> ELF pipeline.
#
# Provides:
#   - eco::compileMlirFileToExecutable / compileMlirBytesToExecutable
#   - eco::linkExecutable
#   - eco_native_lower_and_link / eco_native_lower_and_link_bytes (C ABI)
#
# Consumers:
#   - eco-boot-native (CLI driver): links it for the EcoBackend/EcoPipeline
#     helper functions its main() calls.
#   - The unified `eco` binary (Stage 9): links it so the Eco-side
#     Eco.NativeDriver.lowerAndLink kernel intrinsic can drive lowering and
#     linking in-process via the C ABI.
#
# EcoBackend.cpp / EcoPipeline.cpp / LoweringStats.cpp live in this library
# (not duplicated in the eco-boot-native executable target).
#------------------------------------------------------------------------------

add_library(EcoNativeDriverStatic STATIC
    EcoNativeDriver.cpp
    EcoBackend.cpp
    EcoPipeline.cpp
    LoweringStats.cpp
)

target_include_directories(EcoNativeDriverStatic PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/include
)
target_include_directories(EcoNativeDriverStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
)

target_link_libraries(EcoNativeDriverStatic PUBLIC
    EcoDialect
    BFDialect
    EcoPasses
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
    MLIRTargetLLVMIRExport
    MLIRBuiltinToLLVMIRTranslation
    MLIRLLVMToLLVMIRTranslation
    MLIRExecutionEngine
    LLVMSupport
    LLVMCore
    LLVMTarget
    LLVMX86CodeGen
    LLVMX86AsmParser
    LLVMX86Desc
    LLVMX86Info
    LLVMAsmPrinter
    LLVMCodeGen
    LLVMMC
    LLVMObject
    LLVMPasses
)

target_compile_features(EcoNativeDriverStatic PRIVATE cxx_std_20)
target_compile_options(EcoNativeDriverStatic PRIVATE
    -Wno-ambiguous-reversed-operator -fexceptions)
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(EcoNativeDriverStatic PRIVATE
        ECO_LOWERING_VALIDATION=1)
endif()

#------------------------------------------------------------------------------
# Build the eco-boot executable (AOT native compiler)
#------------------------------------------------------------------------------

# Generate a header file with library paths for eco-boot at build time.
# We use file(GENERATE ...) with generator expressions so the paths resolve
# to the actual build output locations.

set(ECO_BOOT_CONFIG_HEADER "${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoBootConfig.h")

set(ECO_ELM_KERNEL_MODS
    Basics Bitwise Char String List Utils JsArray Debug
    Scheduler Platform Process VirtualDom Json Browser Bytes
    File Http Parser Regex Time Url EffectRegistry
)

set(ECO_KERNEL_MODS File Console Env Process MVar NativeDriver Runtime Http Crash)

#------------------------------------------------------------------------------
# Phase 3: linker + crt path discovery for direct ld invocation.
#
# We invoke the system linker (ld.bfd) directly instead of going through the
# clang++ driver. This means we need to know exactly where crt1.o / crti.o /
# crtn.o / libgcc.a / libstdc++ / the dynamic linker live — paths the driver
# normally figures out for us. Discover them once at configure time via
# `clang -print-file-name=…` and bake the results into EcoBootConfig.h. lld
# can't be embedded as a library (the LLVM 21 install doesn't ship lld dev
# files); we use ld.bfd because it's what `-fuse-ld=bfd` uses and it
# successfully handles the absolute R_X86_64_64 relocations the Elm-compiled
# object carries in .llvm_stackmaps (lld rejects those in PIE mode).
#------------------------------------------------------------------------------

# Use ld.bfd. Don't try to find ld.lld (LLVM 21 lld isn't shipped here, the
# system lld-14 rejects our PIE stackmap relocations).
find_program(ECO_SYSTEM_LD ld REQUIRED)
message(STATUS "Eco AOT linker (direct, no clang++ driver): ${ECO_SYSTEM_LD}")

# Discover crt object files + libgcc via clang. These are absolute paths into
# the system gcc install (Debian: /usr/lib/gcc/x86_64-linux-gnu/12/) and
# multilib dirs (/lib/x86_64-linux-gnu/). They're stable for a given host.
function(_eco_query_clang_path OUT_VAR FLAG)
    execute_process(
        COMMAND ${CMAKE_C_COMPILER} -print-file-name=${FLAG}
        OUTPUT_VARIABLE _path
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    # Normalize via realpath so the baked path doesn't depend on '../' segments.
    get_filename_component(_path "${_path}" REALPATH)
    set(${OUT_VAR} "${_path}" PARENT_SCOPE)
endfunction()

_eco_query_clang_path(ECO_CRT1_O  Scrt1.o)
_eco_query_clang_path(ECO_CRTI_O  crti.o)
_eco_query_clang_path(ECO_CRTN_O  crtn.o)
_eco_query_clang_path(ECO_CRTBEGIN_O crtbeginS.o)
_eco_query_clang_path(ECO_CRTEND_O   crtendS.o)
_eco_query_clang_path(ECO_LIBGCC_A   libgcc.a)
get_filename_component(ECO_GCC_LIBDIR "${ECO_LIBGCC_A}" DIRECTORY)

# Dynamic linker (the program interpreter the PT_INTERP entry points to).
# Hardcoded for x86_64 glibc — the path is part of the platform ABI.
set(ECO_DYNAMIC_LINKER "/lib64/ld-linux-x86-64.so.2")

# Library search dirs for unresolved -l flags. Mirrors `clang -print-search-dirs`.
execute_process(
    COMMAND ${CMAKE_C_COMPILER} -print-search-dirs
    OUTPUT_VARIABLE _search_dirs_raw
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
string(REGEX MATCH "libraries: =([^\n]+)" _ "${_search_dirs_raw}")
set(_libdirs_csv "${CMAKE_MATCH_1}")
string(REPLACE ":" ";" ECO_LIBRARY_DIRS "${_libdirs_csv}")

message(STATUS "Eco AOT crt files:")
message(STATUS "  Scrt1.o:    ${ECO_CRT1_O}")
message(STATUS "  crti.o:     ${ECO_CRTI_O}")
message(STATUS "  crtn.o:     ${ECO_CRTN_O}")
message(STATUS "  crtbeginS:  ${ECO_CRTBEGIN_O}")
message(STATUS "  crtendS:    ${ECO_CRTEND_O}")
message(STATUS "  libgcc.a:   ${ECO_LIBGCC_A}")
message(STATUS "  gcc libdir: ${ECO_GCC_LIBDIR}")

# Build the content string with generator expressions
set(ECO_BOOT_CONFIG_CONTENT "// Auto-generated by CMake. Do not edit.\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#pragma once\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#include <vector>\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#include <string>\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "namespace eco {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "namespace config {\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *entryLib = \"$<TARGET_FILE:EcoEntryStatic>\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *runtimeLib = \"$<TARGET_FILE:EcoRuntimeStatic>\";\n")
# LLVM libunwind — passed as a full library path (not -lunwind) so AOT links
# do NOT accidentally pick up the system (nongnu) libunwind.
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *unwindLib = \"${LLVM_LIBUNWIND_LIBRARY}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *unwindLibDir = \"${LLVM_LIBUNWIND_LIBRARY_DIR}\";\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> elmKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_ELM_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"$<TARGET_FILE:ElmKernel_${mod}>\",\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> ecoKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"$<TARGET_FILE:EcoKernel_${mod}>\",\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

# System libraries pulled in by static kernel archives. The static archives
# only carry their own object code; their PRIVATE link interface (libcurl,
# libssl, libcrypto, libzip) doesn't propagate, so the AOT linker driven by
# eco-boot-native must repeat them on its own command line. We list the
# always-present ones (curl/ssl/crypto/pthread/m/stdc++) directly in
# eco-boot.cpp; libzip is conditional on host availability and travels
# through this generated config.
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> kernelSystemLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
if(ECO_KERNEL_LIBZIP_FOUND)
    foreach(libzip_entry IN LISTS ECO_KERNEL_LIBZIP_LIBRARIES)
        # pkg-config returns bare lib names ("zip"); turn each into "-l<name>"
        # for the linker-args list. Absolute paths are passed as-is.
        if(IS_ABSOLUTE "${libzip_entry}")
            string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"${libzip_entry}\",\n")
        else()
            string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"-l${libzip_entry}\",\n")
        endif()
    endforeach()
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

#--- Phase 3: linker + crt paths for direct ld invocation -----------------
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Phase 3: direct-linker config ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *systemLinker = \"${ECO_SYSTEM_LD}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *dynamicLinker = \"${ECO_DYNAMIC_LINKER}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crt1Obj = \"${ECO_CRT1_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtiObj = \"${ECO_CRTI_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtnObj = \"${ECO_CRTN_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtbeginObj = \"${ECO_CRTBEGIN_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtendObj = \"${ECO_CRTEND_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *libgccA = \"${ECO_LIBGCC_A}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *gccLibDir = \"${ECO_GCC_LIBDIR}\";\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> librarySearchDirs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(_d ${ECO_LIBRARY_DIRS})
    if(_d STREQUAL "")
        continue()
    endif()
    string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"${_d}\",\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "} // namespace config\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "} // namespace eco\n")

file(GENERATE
    OUTPUT "${ECO_BOOT_CONFIG_HEADER}"
    CONTENT "${ECO_BOOT_CONFIG_CONTENT}"
)

add_llvm_executable(eco-boot-native
    eco-boot.cpp
    PARTIAL_SOURCES_INTENDED
)

target_include_directories(eco-boot-native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_BINARY_DIR}/include
)

# Pulls EcoBackend / EcoPipeline / LoweringStats + the full MLIR/LLVM
# pipeline transitively.
target_link_libraries(eco-boot-native PRIVATE
    EcoNativeDriverStatic
)

# eco-boot-native shells out to clang at runtime to link these archives into
# the user's output binary, so they aren't in eco-boot-native's own link line —
# but we still need them up-to-date whenever eco-boot-native itself is built.
#
# NB: ElmKernel and EcoKernel are INTERFACE libraries; add_dependencies() on an
# INTERFACE target is a no-op (no build action attached), so we must list each
# concrete static lib explicitly. Reuse ECO_ELM_KERNEL_MODS / ECO_KERNEL_MODS
# defined above so this list can't drift from the generated EcoBootConfig.h.
set(ECO_BOOT_NATIVE_RUNTIME_DEPS EcoEntryStatic EcoRuntimeStatic)
foreach(mod ${ECO_ELM_KERNEL_MODS})
    list(APPEND ECO_BOOT_NATIVE_RUNTIME_DEPS ElmKernel_${mod})
endforeach()
foreach(mod ${ECO_KERNEL_MODS})
    list(APPEND ECO_BOOT_NATIVE_RUNTIME_DEPS EcoKernel_${mod})
endforeach()
add_dependencies(eco-boot-native ${ECO_BOOT_NATIVE_RUNTIME_DEPS})

target_compile_features(eco-boot-native PRIVATE cxx_std_20)
target_compile_options(eco-boot-native PRIVATE -Wno-ambiguous-reversed-operator -fexceptions)
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(eco-boot-native PRIVATE ECO_LOWERING_VALIDATION=1)
endif()

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
