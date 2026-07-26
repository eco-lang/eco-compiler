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

# Note: elm-kernel-cpp is included from the top-level CMakeLists.txt
# The ElmKernel target is available for linking.

# GC debug assertions: default ON for Debug builds, OFF for Release.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" ON)
else()
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" OFF)
endif()

option(ECO_LOWERING_VALIDATION "Enable validation-only lowering passes (GC liveness audit, post-RS4GC ptr<1>↔i64 boundary verifier; slow, independent of ECO_GC_DEBUG)" OFF)

# Stage D archive-only mode (ECO_GLIBC_OUTPUT_RUNTIME): everything MLIR
# is gated off — find_package(MLIR), TableGen, the dialect/pass/driver
# targets and eco-boot-native. What remains is the toolchain-independent
# half this file also owns: the EcoEntry/Embed/NodeGlue/RuntimeStatic
# targets, the kernel module lists, linker/crt discovery and the
# EcoBootConfig.h generation. This is what lets the glibc-runtime Docker
# stage run on a plain debian image with apt packages instead of the
# multi-hour eco-llvm-debian source image.
# See plans/stage-d-hybrid-link-profiles.md (step 2).
if(NOT ECO_GLIBC_OUTPUT_RUNTIME)

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

# --- macOS: single-copy LLVM/MLIR linkage -----------------------------------
# Homebrew's llvm@21 ships BOTH the static component archives (libLLVMCore.a,
# libMLIRIR.a, ...) AND the aggregate shared libs (libLLVM.dylib,
# libMLIR.dylib). Brew's static MLIR archives are themselves built against
# libLLVM.dylib, so linking the static component targets drags the dylib in
# transitively — every binary then carries TWO copies of LLVM/MLIR global
# state (TypeID registries, attribute uniquer). Under macOS's two-level
# namespace these copies don't merge, so an IntegerAttr/StringAttr built by one
# copy fails isa<> in the other: inherent-attribute verifiers all fail
# ("failed to satisfy constraint") and type checks segfault.
#
# Fix: on Apple, collapse every MLIR/LLVM component-target reference to the
# aggregate dylibs, which are complete supersets — exactly one copy per binary.
# As a bonus this gives the AOT driver every backend target (incl. AArch64)
# instead of the hardcoded X86 component list. Linux keeps its static-only
# pinned tree (one copy already), so the component lists below are unchanged
# there. ECO_MLIR_LIBS / ECO_LLVM_LIBS expand to the aggregate targets on
# Apple and are empty elsewhere (the explicit component lists are kept).
if(APPLE)
    set(ECO_MLIR_LIBS MLIR)
    set(ECO_LLVM_LIBS LLVM)
endif()

else()
    # Replicate the semantically relevant compile flags HandleLLVMOptions
    # would have injected for this directory's surviving targets
    # (EcoRuntimeStatic & friends), so the staged glibc archives match the
    # full build's codegen. Verified against the full build's compile
    # commands; EH is per-target opt-in ($<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>) in both modes.
    add_compile_options(
        -ffunction-sections -fdata-sections
        -fno-semantic-interposition -fvisibility-inlines-hidden)
endif()

# Include directory for generated headers
include_directories(${CMAKE_CURRENT_BINARY_DIR}/include)

# Include directory for source headers (EcoDialect.h, EcoOps.h)
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

if(NOT ECO_GLIBC_OUTPUT_RUNTIME)

# Add LLVM definitions. HandleLLVMOptions (included above) rewrites
# LLVM_DEFINITIONS into a single space-joined string built from the
# top-level directory's COMPILE_DEFINITIONS — which folds in this project's
# own add_compile_definitions (ECO_GC_DEBUG, ENABLE_GC_STATS, ...). Passing
# that unsplit makes add_definitions() treat the whole string as ONE -D flag
# (e.g. -DECO_GC_DEBUG="1 -DENABLE_GC_STATS=1"), redefining the macro to a
# value the preprocessor can't evaluate in #if. Split it back into flags.
separate_arguments(_llvm_defs NATIVE_COMMAND "${LLVM_DEFINITIONS}")
add_definitions(${_llvm_defs})

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

# MLIR component libs for EcoDialect (aggregate dylib on Apple — see the
# single-copy rationale above; static components elsewhere).
if(APPLE)
    set(ECO_ECODIALECT_MLIR_LIBS ${ECO_MLIR_LIBS})
else()
    set(ECO_ECODIALECT_MLIR_LIBS
        MLIRIR MLIRSupport MLIRControlFlowInterfaces MLIRSideEffectInterfaces)
endif()

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
    ${ECO_ECODIALECT_MLIR_LIBS}
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
    Passes/JoinpointNormalization.cpp
    Passes/EcoControlFlowToSCF.cpp
    Passes/UndefinedFunction.cpp
    Passes/CheckEcoClosureCaptures.cpp
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

if(APPLE)
    set(ECO_BFDIALECT_MLIR_LIBS ${ECO_MLIR_LIBS})
else()
    set(ECO_BFDIALECT_MLIR_LIBS MLIRIR MLIRSupport MLIRSideEffectInterfaces)
endif()

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
    ${ECO_BFDIALECT_MLIR_LIBS}
)

# Include directory for BF source headers
target_include_directories(obj.BFDialect PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/BF)

target_compile_features(obj.BFDialect PRIVATE cxx_std_17)
target_compile_options(obj.BFDialect PRIVATE -Wno-ambiguous-reversed-operator)

#------------------------------------------------------------------------------
# Create a library for Eco passes
#------------------------------------------------------------------------------

if(APPLE)
    set(ECO_ECOPASSES_MLIR_LIBS ${ECO_MLIR_LIBS})
else()
    set(ECO_ECOPASSES_MLIR_LIBS
        MLIRIR MLIRAnalysis MLIRSupport MLIRPass MLIRTransforms MLIRFuncDialect
        MLIRArithDialect MLIRControlFlowDialect MLIRSCFDialect MLIRLLVMDialect
        MLIRLLVMCommonConversion MLIRFuncToLLVM MLIRArithToLLVM
        MLIRControlFlowToLLVM MLIRSCFToControlFlow MLIRReconcileUnrealizedCasts)
endif()

add_mlir_library(EcoPasses
    Passes/RCElimination.cpp
    Passes/EcoPAPSimplify.cpp
    Passes/JoinpointNormalization.cpp
    Passes/EcoControlFlowToSCF.cpp
    Passes/EcoTailConversions.cpp
    Passes/UndefinedFunction.cpp
    Passes/CheckEcoClosureCaptures.cpp
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
    ${ECO_ECOPASSES_MLIR_LIBS}
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

if(APPLE)
    set(ECO_ECOGEN_MLIR_LLVM_LIBS ${ECO_MLIR_LIBS} ${ECO_LLVM_LIBS})
else()
    set(ECO_ECOGEN_MLIR_LLVM_LIBS MLIRIR MLIRParser MLIRSupport MLIRFuncDialect LLVMSupport)
endif()

target_link_libraries(ecogen PRIVATE
    EcoDialect
    ${ECO_ECOGEN_MLIR_LLVM_LIBS}
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
    LoweringStats.cpp
    RuntimeSymbols.cpp
    ../jit/EcoJIT.cpp
    ../allocator/StackMap.cpp
    ../allocator/StackUnwind.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ${ECO_ALLOCATOR_PLATFORM_SRCS_RELATIVE}
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/PermanentSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    ../platform/Scheduler.cpp
    ../platform/TimerService.cpp
    ../platform/WaitService.cpp
    ../platform/HttpService.cpp
    ../platform/PlatformRuntime.cpp
    ../platform/PortRuntime.cpp
    PARTIAL_SOURCES_INTENDED
)

target_include_directories(ecoc PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../jit
    ${CMAKE_CURRENT_BINARY_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
)

# Full MLIR/LLVM JIT lib set, shared verbatim by ecoc and EcoRunner. Aggregate
# dylibs on Apple (single-copy — see rationale above); static components else.
#
# Brew's aggregate libMLIR.dylib OMITS the JIT MLIRExecutionEngine; that piece
# is attached separately as a raw archive file via $<TARGET_FILE:...> after
# each add_*_library / target_link_libraries call below. It is NOT placed in
# ECO_JIT_MLIR_LLVM_LIBS because that variable feeds add_mlir_library(EcoRunner
# ... LINK_LIBS ...), which internally calls add_dependencies() — and
# add_dependencies does not evaluate generator expressions, so a
# $<TARGET_FILE:...> entry would be taken as a literal (non-existent) target
# name and fail configure. The bare archive supplies just the missing symbols;
# its IR/Support refs resolve to the dylib already on the link line, preserving
# the single-copy TypeID invariant (avoiding the two-copy split the MLIR
# CMake target would cause via its INTERFACE_LINK_LIBRARIES).
if(APPLE)
    set(ECO_JIT_MLIR_LLVM_LIBS ${ECO_MLIR_LIBS} ${ECO_LLVM_LIBS})
else()
    set(ECO_JIT_MLIR_LLVM_LIBS
        MLIRIR MLIRParser MLIRPass MLIRSupport MLIRTransforms MLIRFuncDialect
        MLIRFuncAllExtensions MLIRArithDialect MLIRControlFlowDialect
        MLIRSCFDialect MLIRLLVMDialect MLIRLLVMCommonConversion MLIRFuncToLLVM
        MLIRArithToLLVM MLIRControlFlowToLLVM MLIRSCFToControlFlow
        MLIRReconcileUnrealizedCasts MLIRExecutionEngine MLIRTargetLLVMIRExport
        MLIRBuiltinToLLVMIRTranslation MLIRLLVMToLLVMIRTranslation
        LLVMSupport LLVMCore LLVMOrcJIT)
endif()

target_link_libraries(ecoc PRIVATE
    EcoDialect
    BFDialect
    EcoPasses
    ElmKernel
    ${ECO_JIT_MLIR_LLVM_LIBS}
)

# Apple-only: pull in the MLIRExecutionEngine archive file directly (not the
# CMake target — see the comment on ECO_JIT_MLIR_LLVM_LIBS above). The bare
# archive supplies the symbols brew's libMLIR.dylib omits; its IR/Support refs
# resolve to the dylib already on the link line, preserving the single-copy
# TypeID invariant. target_link_libraries evaluates $<TARGET_FILE:...>
# correctly; the dependency on the imported target is implicit (imported
# targets are not built so no add_dependencies is needed).
if(APPLE)
    target_link_libraries(ecoc PRIVATE $<TARGET_FILE:MLIRExecutionEngine>)
endif()

target_compile_features(ecoc PRIVATE cxx_std_20)
target_compile_options(ecoc PRIVATE -Wno-ambiguous-reversed-operator)

# The runtime code uses exceptions, so we need to enable them
# (LLVM/MLIR disables exceptions by default)
target_compile_options(ecoc PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(ecoc PRIVATE ECO_LOWERING_VALIDATION=1)
endif()

# Need pthreads for the runtime
find_package(Threads REQUIRED)
target_link_libraries(ecoc PRIVATE Threads::Threads)

# libunwind for stack unwinding in GC root scanning — LLVM's libunwind,
# located via cmake/LLVMLibunwind.cmake from the top-level CMakeLists.
target_link_libraries(ecoc PRIVATE eco::llvm_libunwind)

# HttpService.cpp (compiled directly into ecoc) needs <curl/curl.h>. Under
# ECO_STATIC OR WIN32 the system curl/curl.h is absent and curl is vendored
# via FetchContent, so the include dir must flow from the libcurl_static
# target. (On Windows the same vendoring is used with CURL_USE_SCHANNEL
# instead of OpenSSL.)
if(ECO_STATIC OR WIN32)
    target_link_libraries(ecoc PRIVATE libcurl_static)
else()
    find_package(CURL REQUIRED)
    target_link_libraries(ecoc PRIVATE CURL::libcurl)
endif()

#------------------------------------------------------------------------------
# Build the EcoRunner library (for in-process test execution)
#------------------------------------------------------------------------------

add_mlir_library(EcoRunner
    EcoRunner.cpp
    EcoBackend.cpp
    EcoPipeline.cpp
    LoweringStats.cpp
    RuntimeSymbols.cpp
    ../jit/EcoJIT.cpp
    ../allocator/StackMap.cpp
    ../allocator/StackUnwind.cpp
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ${ECO_ALLOCATOR_PLATFORM_SRCS_RELATIVE}
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/PermanentSpace.cpp
    ../allocator/RootSet.cpp
    ../allocator/ThreadLocalHeap.cpp
    ../allocator/GCStats.cpp
    ../allocator/StringOps.cpp
    ../allocator/ListOps.cpp
    ../allocator/BytesOps.cpp
    ../allocator/ElmBytesRuntime.cpp
    ../platform/Scheduler.cpp
    ../platform/TimerService.cpp
    ../platform/WaitService.cpp
    ../platform/HttpService.cpp
    ../platform/PlatformRuntime.cpp
    ../platform/PortRuntime.cpp
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
    ${ECO_JIT_MLIR_LLVM_LIBS}
)

target_include_directories(obj.EcoRunner PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../jit
    ${CMAKE_CURRENT_SOURCE_DIR}/BF
)

target_compile_features(obj.EcoRunner PRIVATE cxx_std_20)
target_compile_options(obj.EcoRunner PRIVATE -Wno-ambiguous-reversed-operator $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
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

# Apple-only: MLIRExecutionEngine archive file (see ECO_JIT_MLIR_LLVM_LIBS
# comment above for why this can't go through add_mlir_library's LINK_LIBS).
# PUBLIC so it propagates to the static libEcoRunner.a's transitive consumers
# (test/stress-test), which is the whole point — those binaries are the ones
# that were missing mlir::ExecutionEngine::registerSymbols.
if(APPLE)
    target_link_libraries(EcoRunner PUBLIC $<TARGET_FILE:MLIRExecutionEngine>)
endif()

# HttpService.cpp (compiled into obj.EcoRunner) needs <curl/curl.h>. Same
# reasoning as ecoc above — vendored curl under ECO_STATIC.
if(ECO_STATIC)
    target_link_libraries(obj.EcoRunner PRIVATE libcurl_static)
else()
    target_link_libraries(obj.EcoRunner PRIVATE CURL::libcurl)
endif()

endif() # NOT ECO_GLIBC_OUTPUT_RUNTIME — MLIR dialects/passes/tools half

#------------------------------------------------------------------------------
# Build the EcoRuntimeStatic library (for linking into AOT-compiled binaries)
#------------------------------------------------------------------------------

add_library(EcoRuntimeStatic STATIC
    ../allocator/RuntimeExports.cpp
    ../allocator/Allocator.cpp
    ${ECO_ALLOCATOR_PLATFORM_SRCS_RELATIVE}
    ../allocator/HeapConfigJson.cpp
    ../allocator/NurserySpace.cpp
    ../allocator/OldGenSpace.cpp
    ../allocator/PermanentSpace.cpp
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
    ../platform/WaitService.cpp
    ../platform/HttpService.cpp
    ../platform/PlatformRuntime.cpp
    ../platform/PortRuntime.cpp
)

target_include_directories(EcoRuntimeStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../elm-kernel-cpp/src
)

target_compile_features(EcoRuntimeStatic PRIVATE cxx_std_20)
target_compile_options(EcoRuntimeStatic PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_ASSERTS_ON)
    target_compile_options(EcoRuntimeStatic PRIVATE -UNDEBUG)
endif()

# PUBLIC so AOT consumers inherit LLVM libunwind's include dir, library, and
# rpath flag. See cmake/LLVMLibunwind.cmake.
target_link_libraries(EcoRuntimeStatic PUBLIC eco::llvm_libunwind)

# HttpService.cpp includes <curl/curl.h>. Under ECO_STATIC OR WIN32 curl is
# vendored via FetchContent (no system /usr/include/curl), so the include
# dir must come from the libcurl_static target; otherwise CURL::libcurl
# provides it.
if(ECO_STATIC OR WIN32)
    target_link_libraries(EcoRuntimeStatic PRIVATE libcurl_static)
else()
    find_package(CURL REQUIRED)
    target_link_libraries(EcoRuntimeStatic PRIVATE CURL::libcurl)
endif()

if(ECO_GC_DEBUG)
    target_compile_definitions(EcoRuntimeStatic PRIVATE ECO_GC_DEBUG=1)
endif()

# ECO_KERNEL_DEBUG: enables curl-side request/response tracing in
# platform/HttpService.cpp. Same ECO_KLOG macro as the kernel libs.
if(ECO_KERNEL_DEBUG)
    target_compile_definitions(EcoRuntimeStatic PRIVATE ECO_KERNEL_DEBUG)
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

#------------------------------------------------------------------------------
# EcoEmbedStatic: host-embedding entry (eco_app_start/stop/join) for library
# outputs (.so/.o). Replaces EcoEntryStatic's main() when the program is
# linked into a host application. See runtime/src/embed/eco_embed.h.
#------------------------------------------------------------------------------

add_library(EcoEmbedStatic STATIC
    ../embed/eco_embed.cpp
    eco_native_stub.cpp
)

target_include_directories(EcoEmbedStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
)

target_compile_features(EcoEmbedStatic PRIVATE cxx_std_20)
target_compile_options(EcoEmbedStatic PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_ASSERTS_ON)
    target_compile_options(EcoEmbedStatic PRIVATE -UNDEBUG)
endif()
if(ECO_GC_DEBUG)
    target_compile_definitions(EcoEmbedStatic PRIVATE ECO_GC_DEBUG=1)
endif()

#------------------------------------------------------------------------------
# EcoNodeGlue: N-API addon glue for `.node` output targets. Wraps the embed
# API in the JS-target-compatible `Elm.<Module>.init({flags})` shape so Node
# hosts written against compiled-to-JS Elm run unaltered against native code.
#------------------------------------------------------------------------------

# Node-API headers: prefer the vendored copy (runtime/third_party/
# node-api-headers — ABI-stable N-API, MIT; see its README) so EcoNodeGlue
# and `.node` output support build on EVERY host, including the Alpine
# release image, which ships no node headers (this used to silently
# disable .node outputs there — Stage D fix). System paths remain as
# fallback and ECO_NODE_API_INCLUDE_DIR stays overridable via the cache.
find_path(ECO_NODE_API_INCLUDE_DIR node_api.h
    PATHS ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/node-api-headers
          /usr/include/node /usr/local/include/node)

if(ECO_NODE_API_INCLUDE_DIR)
    add_library(EcoNodeGlue STATIC
        ../embed/eco_node_addon.cpp
    )
    target_include_directories(EcoNodeGlue PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/..
        ${ECO_NODE_API_INCLUDE_DIR}
    )
    target_compile_features(EcoNodeGlue PRIVATE cxx_std_20)
    target_compile_options(EcoNodeGlue PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
else()
    message(STATUS "node_api.h not found — .node output targets disabled")
endif()

target_compile_features(EcoEntryStatic PRIVATE cxx_std_20)
target_compile_options(EcoEntryStatic PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_ASSERTS_ON)
    target_compile_options(EcoEntryStatic PRIVATE -UNDEBUG)
endif()
if(ECO_GC_DEBUG)
    target_compile_definitions(EcoEntryStatic PRIVATE ECO_GC_DEBUG=1)
endif()

if(NOT ECO_GLIBC_OUTPUT_RUNTIME) # MLIR half: the AOT driver library

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
    EcoBootConfig.cpp
)

target_include_directories(EcoNativeDriverStatic PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/include
)
target_include_directories(EcoNativeDriverStatic PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/..
)

# AOT driver MLIR/LLVM libs. On Apple the aggregate libLLVM.dylib carries every
# backend target (incl. the host AArch64) — the static branch keeps the
# historical X86 component list for the Linux/glibc cross path. Single-copy on
# Apple (see rationale above).
if(APPLE)
    set(ECO_AOT_MLIR_LLVM_LIBS ${ECO_MLIR_LIBS} ${ECO_LLVM_LIBS})
else()
    set(ECO_AOT_MLIR_LLVM_LIBS
        MLIRIR MLIRParser MLIRPass MLIRSupport MLIRTransforms MLIRFuncDialect
        MLIRFuncAllExtensions MLIRArithDialect MLIRControlFlowDialect
        MLIRSCFDialect MLIRLLVMDialect MLIRLLVMCommonConversion MLIRFuncToLLVM
        MLIRArithToLLVM MLIRControlFlowToLLVM MLIRSCFToControlFlow
        MLIRReconcileUnrealizedCasts MLIRTargetLLVMIRExport
        MLIRBuiltinToLLVMIRTranslation MLIRLLVMToLLVMIRTranslation
        MLIRExecutionEngine
        LLVMSupport LLVMCore LLVMTarget LLVMX86CodeGen LLVMX86AsmParser
        LLVMX86Desc LLVMX86Info LLVMAsmPrinter LLVMCodeGen LLVMMC LLVMObject
        LLVMPasses)
endif()

target_link_libraries(EcoNativeDriverStatic PUBLIC
    EcoDialect
    BFDialect
    EcoPasses
    ${ECO_AOT_MLIR_LLVM_LIBS}
)

target_compile_features(EcoNativeDriverStatic PRIVATE cxx_std_20)
target_compile_options(EcoNativeDriverStatic PRIVATE
    -Wno-ambiguous-reversed-operator $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(EcoNativeDriverStatic PRIVATE
        ECO_LOWERING_VALIDATION=1)
endif()

endif() # NOT ECO_GLIBC_OUTPUT_RUNTIME — AOT driver library

#------------------------------------------------------------------------------
# Build the eco-boot executable (AOT native compiler)
#------------------------------------------------------------------------------

# Generate a header file with library paths for eco-boot at build time.
# We use file(GENERATE ...) with generator expressions so the paths resolve
# to the actual build output locations.

set(ECO_BOOT_CONFIG_HEADER "${CMAKE_CURRENT_BINARY_DIR}/include/eco/EcoBootConfig.h")

# CACHE INTERNAL so the top-level CMakeLists.txt's Stage C bundle install
# rules can iterate the same lists (CMake otherwise scopes these to this
# subdirectory only — see commit history for why this matters for bundle
# completeness).
set(ECO_ELM_KERNEL_MODS
    Basics Bitwise Char String List Utils JsArray Debug
    Scheduler Platform Process VirtualDom Json Browser Bytes
    File Http Parser Regex Time Url EffectRegistry
    CACHE INTERNAL "Elm kernel module names — drives static lib targets and bundle install"
)

set(ECO_KERNEL_MODS File Console Env Process MVar NativeDriver Runtime Http Crash
    CACHE INTERNAL "Eco kernel module names — drives static lib targets and bundle install"
)

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

# Linker choice for the AOT path.
#   - Glibc (Stage A.5): ld.bfd. lld-14 on Debian rejects our PIE stackmap
#     relocations, and LLVM 21 lld isn't on the Debian image.
#   - musl/Stage B.5: ld.lld. Q3 RESOLVED in lld's favour for Stage B (non-PIE
#     static — lld accepts the stackmap relocs there). BFD is the documented
#     fallback (binutils is in the Stage B image) if ld.lld is absent.
#   - Windows: skipped. The AOT path on Win64 invokes clang-cl/lld-link via
#     EcoNativeDriver::linkExecutableWindows (currently a v1 stub — see
#     plans/build-on-windows.md W4 item 17); the crt/libgcc/ld discovery
#     below is all glibc-specific and produces nonsense on Windows.
if(NOT WIN32)
    if(ECO_STATIC_MUSL)
        find_program(ECO_SYSTEM_LD NAMES ld.lld lld ld REQUIRED)
    else()
        find_program(ECO_SYSTEM_LD ld REQUIRED)
    endif()
    message(STATUS "Eco AOT linker (direct, no clang++ driver): ${ECO_SYSTEM_LD}")
else()
    set(ECO_SYSTEM_LD "lld-link.exe")  # placeholder; linkExecutableWindows stub
endif()

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
    # Set in caller's scope (used immediately for messages/checks) AND in the
    # cache so the top-level CMakeLists.txt's Stage C bundle install rules can
    # reference the same paths.
    set(${OUT_VAR} "${_path}" PARENT_SCOPE)
    set(${OUT_VAR} "${_path}" CACHE INTERNAL "Resolved by _eco_query_clang_path(${FLAG})")
endfunction()

if(NOT WIN32)
    _eco_query_clang_path(ECO_CRT1_O  Scrt1.o)
    _eco_query_clang_path(ECO_CRTI_O  crti.o)
    _eco_query_clang_path(ECO_CRTN_O  crtn.o)
    _eco_query_clang_path(ECO_CRTBEGIN_O crtbeginS.o)
    _eco_query_clang_path(ECO_CRTEND_O   crtendS.o)
    _eco_query_clang_path(ECO_LIBGCC_A   libgcc.a)
    get_filename_component(ECO_GCC_LIBDIR "${ECO_LIBGCC_A}" DIRECTORY)
else()
    # Windows: placeholder values for EcoBootConfig.h layout stability.
    # linkExecutableWindows is a v1 stub and never reads them.
    set(ECO_CRT1_O ""        CACHE INTERNAL "Windows placeholder")
    set(ECO_CRTI_O ""        CACHE INTERNAL "Windows placeholder")
    set(ECO_CRTN_O ""        CACHE INTERNAL "Windows placeholder")
    set(ECO_CRTBEGIN_O ""    CACHE INTERNAL "Windows placeholder")
    set(ECO_CRTEND_O ""      CACHE INTERNAL "Windows placeholder")
    set(ECO_LIBGCC_A ""      CACHE INTERNAL "Windows placeholder")
    set(ECO_GCC_LIBDIR ""    CACHE INTERNAL "Windows placeholder")
endif()

# Stage B.5: non-PIE static crt prefix/epilogue + musl libc++/compiler-rt
# stack. Only resolved under ECO_STATIC_MUSL; queries are cheap and produce
# stable absolute paths so the EcoBootConfig.h generation below can bake them
# unconditionally without branching.
if(ECO_STATIC_MUSL)
    _eco_query_clang_path(ECO_CRT1_O_STATIC     crt1.o)
    # Stage C bundle: use compiler-rt's crtbegin/crtend (clang_rt.crtbegin-<arch>.o)
    # rather than gcc's. Keeps the runtime stack consistent — libc++ + compiler-rt
    # builtins + LLVM libunwind — so the bundle only carries compiler-rt artifacts.
    _eco_query_clang_path(ECO_CRTBEGIN_O_STATIC clang_rt.crtbegin-x86_64.o)
    _eco_query_clang_path(ECO_CRTEND_O_STATIC   clang_rt.crtend-x86_64.o)
    _eco_query_clang_path(ECO_LIBC_A            libc.a)
    _eco_query_clang_path(ECO_LIBCXX_A          libc++.a)
    _eco_query_clang_path(ECO_LIBCXXABI_A       libc++abi.a)
    # compiler-rt builtins archive. `--print-libgcc-file-name` returns
    # whichever runtime `-rtlib` selects — under `-rtlib=compiler-rt` that's
    # `libclang_rt.builtins-<arch>.a`. Use execute_process directly rather
    # than _eco_query_clang_path (different clang flag, not -print-file-name).
    execute_process(
        COMMAND ${CMAKE_C_COMPILER} --print-libgcc-file-name -rtlib=compiler-rt
        OUTPUT_VARIABLE ECO_COMPILER_RT_BUILTINS_A
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    get_filename_component(ECO_COMPILER_RT_BUILTINS_A
        "${ECO_COMPILER_RT_BUILTINS_A}" REALPATH)
    # Mirror _eco_query_clang_path's CACHE INTERNAL handling so the top-level
    # bundle install rules see this path.
    set(ECO_COMPILER_RT_BUILTINS_A "${ECO_COMPILER_RT_BUILTINS_A}"
        CACHE INTERNAL "compiler-rt builtins archive (clang --print-libgcc-file-name)")
    message(STATUS "Eco AOT (musl/static) paths:")
    message(STATUS "  crt1.o:                  ${ECO_CRT1_O_STATIC}")
    message(STATUS "  clang_rt.crtbegin.o:     ${ECO_CRTBEGIN_O_STATIC}")
    message(STATUS "  clang_rt.crtend.o:       ${ECO_CRTEND_O_STATIC}")
    message(STATUS "  libc.a:                  ${ECO_LIBC_A}")
    message(STATUS "  libc++.a:                ${ECO_LIBCXX_A}")
    message(STATUS "  libc++abi.a:             ${ECO_LIBCXXABI_A}")
    message(STATUS "  libclang_rt.builtins.a:  ${ECO_COMPILER_RT_BUILTINS_A}")
    # Fail fast if any of the queries returned the input filename unchanged
    # (clang -print-file-name's "not found" behavior). Each path must resolve
    # to an absolute file present on the build host.
    foreach(_p
        ECO_CRT1_O_STATIC ECO_CRTBEGIN_O_STATIC ECO_CRTEND_O_STATIC
        ECO_LIBC_A ECO_LIBCXX_A ECO_LIBCXXABI_A ECO_COMPILER_RT_BUILTINS_A)
        if(NOT IS_ABSOLUTE "${${_p}}")
            message(FATAL_ERROR
                "Eco Stage B: ${_p} did not resolve to an absolute path: '${${_p}}'")
        endif()
    endforeach()

    # Two ld.lld variables for two distinct use cases:
    #
    #  ECO_BUILD_LD_LLD — used at *build time* by eco-boot-native to link
    #    the eco binary itself (and the AOT-built bootstrap stages). Must
    #    be able to read Alpine's debug-compressed musl libc.a, which means
    #    it needs LLVM_ENABLE_ZLIB=ON. The system /usr/bin/ld.lld (from
    #    apk's lld package) qualifies.
    #
    #  ECO_BUNDLED_LD_LLD — copied into the distribution bundle and used
    #    at *user-binary build time* by the installed eco. Must be fully
    #    static so it runs on any Linux host. Built standalone from the
    #    Stage 1 LLVM image into /opt/llvm-mlir/bin/ld.lld. Doesn't need
    #    zlib because the install rule strips debug info from every
    #    bundled archive so nothing in the link is compressed.
    #
    # `bundledLinker.buildPath` in EcoBootConfig.h points at ECO_BUILD_LD_LLD
    # so that eco-boot-native at build time picks the zlib-capable system
    # lld; the install tree later puts ECO_BUNDLED_LD_LLD in
    # lib/eco-runtime/, which the runtime resolver prefers when present.
    # Build-time lld — must be the zlib-capable apk one (handles Alpine's
    # debug-compressed musl libc.a). The standard PATH search picks
    # /usr/bin/ld.lld (apk's lld package).
    find_program(ECO_BUILD_LD_LLD ld.lld REQUIRED)
    # Bundled static lld lives outside PATH at /opt/llvm-mlir/libexec/eco-bundle/
    # so clang's `-fuse-ld=lld` in the host build never accidentally picks it.
    # Built with -static (and LLVM_ENABLE_ZLIB=OFF) as part of the Stage 1 LLVM
    # build; docker/llvm-alpine.Dockerfile resolves the bin/ld.lld symlink, copies
    # the real static binary here, and hard-fails if it is not fully static.
    find_program(ECO_BUNDLED_LD_LLD ld.lld
        PATHS /opt/llvm-mlir/libexec/eco-bundle
        NO_DEFAULT_PATH)

    # Bundling the build-time lld (the dynamic apk /usr/bin/ld.lld) into the
    # "static" distribution is a portability trap: that linker is musl-dynamic
    # and NEEDs liblld*/libLLVM/libstdc++/musl libc, so the installed eco could
    # only link user binaries on the exact build host. Refuse to ship it; a dev
    # who wants a throwaway local bundle opts in explicitly.
    option(ECO_ALLOW_NONPORTABLE_LD
        "Bundle a non-static ld.lld when no static one exists (NON-portable bundle; dev/local only)"
        OFF)

    if(NOT ECO_BUNDLED_LD_LLD)
        if(ECO_ALLOW_NONPORTABLE_LD)
            # Override the CACHE entry (not just a local variable): find_program
            # above wrote ECO_BUNDLED_LD_LLD-NOTFOUND into the cache, and the
            # install(PROGRAMS ${ECO_BUNDLED_LD_LLD}) rule that bundles the
            # linker lives in the top-level CMakeLists.txt — a different
            # directory scope. A plain set() here would only shadow the cache in
            # this subdirectory, leaving the install to see the stale value.
            set(ECO_BUNDLED_LD_LLD "${ECO_BUILD_LD_LLD}" CACHE FILEPATH
                "lld copied into the distribution bundle" FORCE)
            message(WARNING
                "Stage C: /opt/llvm-mlir/libexec/eco-bundle/ld.lld not found — "
                "ECO_ALLOW_NONPORTABLE_LD=ON, so bundling ${ECO_BUILD_LD_LLD}. "
                "The resulting bundle is NOT host-portable.")
        else()
            message(FATAL_ERROR
                "Stage C: /opt/llvm-mlir/libexec/eco-bundle/ld.lld not found. The "
                "distribution bundle requires a fully-static ld.lld so the "
                "installed eco can link user binaries on any host. Build it in the "
                "Stage 1 LLVM image (docker/llvm-alpine.Dockerfile builds lld with "
                "-static and copies it to libexec/eco-bundle/), or set "
                "-DECO_ALLOW_NONPORTABLE_LD=ON for a throwaway, non-portable local "
                "bundle.")
        endif()
    endif()

    # Whatever we are about to bundle MUST be fully static, or the installed eco
    # cannot link user binaries on other hosts. Catch a dynamic linker (e.g. the
    # apk lld, which has NEEDED entries) even when one was found at the bundle
    # path — guards against a stale/wrong file slipping through.
    if(CMAKE_READELF AND ECO_BUNDLED_LD_LLD)
        execute_process(
            COMMAND "${CMAKE_READELF}" -d "${ECO_BUNDLED_LD_LLD}"
            OUTPUT_VARIABLE _eco_bundled_lld_dynsec
            ERROR_QUIET)
        if(_eco_bundled_lld_dynsec MATCHES "NEEDED" AND NOT ECO_ALLOW_NONPORTABLE_LD)
            message(FATAL_ERROR
                "Stage C: the ld.lld to be bundled (${ECO_BUNDLED_LD_LLD}) is "
                "dynamically linked (NEEDED entries present) and will not run on "
                "hosts lacking its libc/loader. Provide a fully-static ld.lld "
                "(see docker/llvm-alpine.Dockerfile) or set "
                "-DECO_ALLOW_NONPORTABLE_LD=ON to override.")
        endif()
    endif()
    message(STATUS "  ld.lld (build-time):     ${ECO_BUILD_LD_LLD}")
    message(STATUS "  ld.lld (bundled):        ${ECO_BUNDLED_LD_LLD}")
endif()

# Dynamic linker (the program interpreter the PT_INTERP entry points to).
# Hardcoded for x86_64 glibc — the path is part of the platform ABI. Unused
# under ECO_STATIC_MUSL (the link is `-static`, no PT_INTERP), but kept as a
# stable string so EcoBootConfig.h's layout is identical across profiles.
set(ECO_DYNAMIC_LINKER "/lib64/ld-linux-x86-64.so.2")

# Library search dirs for unresolved -l flags. Mirrors `clang -print-search-dirs`.
if(NOT WIN32)
    execute_process(
        COMMAND ${CMAKE_C_COMPILER} -print-search-dirs
        OUTPUT_VARIABLE _search_dirs_raw
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    string(REGEX MATCH "libraries: =([^\n]+)" _ "${_search_dirs_raw}")
    set(_libdirs_csv "${CMAKE_MATCH_1}")
    string(REPLACE ":" ";" ECO_LIBRARY_DIRS "${_libdirs_csv}")
else()
    set(ECO_LIBRARY_DIRS "" CACHE INTERNAL "Windows placeholder — discovered at link time by lld-link")
endif()

if(NOT APPLE AND NOT WIN32)
    message(STATUS "Eco AOT crt files:")
    message(STATUS "  Scrt1.o:    ${ECO_CRT1_O}")
    message(STATUS "  crti.o:     ${ECO_CRTI_O}")
    message(STATUS "  crtn.o:     ${ECO_CRTN_O}")
    message(STATUS "  crtbeginS:  ${ECO_CRTBEGIN_O}")
    message(STATUS "  crtendS:    ${ECO_CRTEND_O}")
    message(STATUS "  libgcc.a:   ${ECO_LIBGCC_A}")
endif()

#--- Phase 3 (Darwin): AOT link driver discovery ----------------------------
# Darwin uses clang as the link driver (much simpler than direct ld64): the
# crt prefix/epilogue is gone, libSystem/libc++/libcurl/libz come from the
# SDK as .tbd stubs, and ld64 ad-hoc-signs arm64 outputs automatically. The
# only project-time dep not in the SDK is libzip — bundled as a static .a.
#
# The Linux Phase 3 discovery above still ran on Darwin but produces
# nonsense paths (clang's `-print-file-name=Scrt1.o` returns the filename
# unchanged when the file doesn't exist). Those constants are emitted into
# EcoBootConfig.h for layout-stability across platforms but the Darwin
# code path in EcoNativeDriver.cpp never reads them.
if(APPLE)
    execute_process(
        COMMAND xcrun -f clang
        OUTPUT_VARIABLE ECO_DARWIN_CLANG
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _xcrun_rc)
    if(NOT _xcrun_rc EQUAL 0 OR ECO_DARWIN_CLANG STREQUAL "")
        message(FATAL_ERROR
            "Eco AOT (Darwin): `xcrun -f clang` failed. "
            "Install Xcode Command Line Tools (xcode-select --install).")
    endif()
    execute_process(
        COMMAND xcrun --show-sdk-path
        OUTPUT_VARIABLE ECO_DARWIN_SDK_ROOT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _xcrun_rc)
    if(NOT _xcrun_rc EQUAL 0 OR ECO_DARWIN_SDK_ROOT STREQUAL "")
        message(FATAL_ERROR "Eco AOT (Darwin): `xcrun --show-sdk-path` failed.")
    endif()

    # Target arch — match host. Cross-arch (lipo / universal binaries) is a
    # follow-up; AOT users can already pick `eco make --target=…` if we ever
    # plumb that, but for v1 the host arch is the only target.
    if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
        set(ECO_DARWIN_ARCH "arm64")
    elseif(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "x86_64")
        set(ECO_DARWIN_ARCH "x86_64")
    else()
        message(FATAL_ERROR
            "Eco AOT (Darwin): unsupported host arch ${CMAKE_HOST_SYSTEM_PROCESSOR}")
    endif()

    # libzip is not in the macOS SDK and brew's formula ships only a dylib.
    # eco-kernel-cpp/CMakeLists.txt vendors libzip via FetchContent under
    # APPLE (mirrors the ECO_STATIC path) and exposes the `zip` CMake
    # target; we read its built archive path via $<TARGET_FILE:zip>.
    # eco-kernel-cpp is add_subdirectory()'d AFTER runtime/src/codegen at
    # the top level (see CMakeLists.txt), so the target doesn't exist yet
    # at configure time of this subdir — the generator expression resolves
    # later, at file(GENERATE) time, by which point all subdirs are done.
    # If `zip` is missing at that point CMake errors with a clear message.
    set(ECO_DARWIN_LIBZIP_A "$<TARGET_FILE:zip>")

    # OpenSSL: brew's openssl@3 (keg-only at /opt/homebrew/opt/openssl@3/).
    # Required for AOT link because (a) the vendored libzip's CMake
    # configure picks up brew openssl as a build dep and compiles
    # zip_crypto_openssl.c (auto-detect fallback even with ENABLE_OPENSSL=OFF),
    # and (b) eco-kernel-cpp/src/eco/Http.cpp uses SHA1() directly via
    # <openssl/sha.h>. plans/build-on-mac.md sketches replacing both with
    # CommonCrypto as a follow-up; for v1 we link the brew static archives.
    find_file(ECO_DARWIN_LIBSSL_A NAMES libssl.a
        PATHS /opt/homebrew/opt/openssl@3/lib /usr/local/opt/openssl@3/lib
        NO_DEFAULT_PATH)
    find_file(ECO_DARWIN_LIBCRYPTO_A NAMES libcrypto.a
        PATHS /opt/homebrew/opt/openssl@3/lib /usr/local/opt/openssl@3/lib
        NO_DEFAULT_PATH)
    if(NOT ECO_DARWIN_LIBSSL_A OR NOT ECO_DARWIN_LIBCRYPTO_A)
        message(FATAL_ERROR
            "Eco AOT (Darwin): static libssl.a/libcrypto.a not found in "
            "brew's openssl@3 keg-only prefix. Run `brew install openssl@3`.")
    endif()
    # Re-publish to CACHE INTERNAL so compiler/CMakeLists.txt's Stage 9
    # link (eco_apply_unified_link) and the top-level Stage 9 install rule
    # see the same paths without re-running find_file from each subdir.
    set(ECO_DARWIN_LIBSSL_A "${ECO_DARWIN_LIBSSL_A}"
        CACHE INTERNAL "brew openssl@3 libssl.a (Darwin AOT link)")
    set(ECO_DARWIN_LIBCRYPTO_A "${ECO_DARWIN_LIBCRYPTO_A}"
        CACHE INTERNAL "brew openssl@3 libcrypto.a (Darwin AOT link)")

    message(STATUS "Eco AOT (Darwin) paths:")
    message(STATUS "  clang:       ${ECO_DARWIN_CLANG}")
    message(STATUS "  SDK root:    ${ECO_DARWIN_SDK_ROOT}")
    message(STATUS "  arch:        ${ECO_DARWIN_ARCH}")
    message(STATUS "  libzip.a:    ${ECO_DARWIN_LIBZIP_A}")
    message(STATUS "  libssl.a:    ${ECO_DARWIN_LIBSSL_A}")
    message(STATUS "  libcrypto.a: ${ECO_DARWIN_LIBCRYPTO_A}")
else()
    # Stubbed empty on non-Darwin so the EcoBootConfig.h emission below is
    # platform-uniform; EcoNativeDriver.cpp's non-Darwin code paths never
    # read these.
    set(ECO_DARWIN_CLANG "")
    set(ECO_DARWIN_SDK_ROOT "")
    set(ECO_DARWIN_ARCH "")
    set(ECO_DARWIN_LIBZIP_A "")
    set(ECO_DARWIN_LIBSSL_A "")
    set(ECO_DARWIN_LIBCRYPTO_A "")
endif()
message(STATUS "  gcc libdir: ${ECO_GCC_LIBDIR}")

# Build the content string with generator expressions.
#
# The header carries two parallel pieces of information per runtime file:
#
#   1. A `buildPath` — the absolute path resolved at CMake configure time on
#      the build host. Used by `eco-boot-native` *during the build* to AOT-
#      compile stage9.mlir (since the bundle install tree doesn't exist yet),
#      and as a fallback for any consumer that runs outside the bundle.
#
#   2. A `basename` + `subdir` — the layout the installed bundle uses
#      (`lib/eco-runtime/<subdir>/<basename>`). The runtime resolver in
#      EcoBootConfig.cpp prefers this when ECO_RUNTIME_DIR is set or when
#      the auto-resolved `<exe>/../lib/eco-runtime/` exists.
#
# This dual representation means the same generated header serves both the
# build-time eco-boot-native (which has no bundle) and the installed eco
# (which uses the bundle). No #ifdef, no two-pass codegen.
set(ECO_BOOT_CONFIG_CONTENT "// Auto-generated by CMake. Do not edit.\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#pragma once\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#include <vector>\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "#include <string>\n\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "namespace eco {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "namespace config {\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT
    "// Bundle layout descriptor for a single runtime file. resolveFile()\n"
    "// returns ECO_RUNTIME_DIR/<subdir>/<basename> if that env-var is set,\n"
    "// else <exe>/../lib/eco-runtime/<subdir>/<basename> when that path\n"
    "// exists, else falls back to buildPath. Linux-only.\n"
    "struct RuntimeFile {\n"
    "    const char *basename;\n"
    "    const char *subdir;    // \"\", \"crt\", or \"project\"\n"
    "    const char *buildPath;\n"
    "};\n\n"
    "std::string runtimeDir();\n"
    "std::string resolveFile(const RuntimeFile &f);\n\n"
    "// Stage D capability probe: true when the runtime tree carries the\n"
    "// glibc output-profile inputs (lib/eco-runtime/glibc/), which the\n"
    "// .so/.node link profile requires under ECO_STATIC_MUSL bundles.\n"
    "bool hasGlibcOutputProfile();\n\n")

# Path baked into nodeGlueLib (empty when node headers are unavailable —
# resolveFile() then fails with a clear message if a .node link is attempted).
if(TARGET EcoNodeGlue)
    set(ECO_NODE_GLUE_PATH "$<TARGET_FILE:EcoNodeGlue>")
else()
    set(ECO_NODE_GLUE_PATH "")
endif()

# --- Project static archives ---------------------------------------------
# Generator expressions resolve to the actual build-tree paths
# (libElmKernel_Basics.a etc.). Basenames are derived at codegen time so
# the bundle layout knows them without re-querying CMake at runtime.
string(APPEND ECO_BOOT_CONFIG_CONTENT
    "inline RuntimeFile entryLib   {\"libEcoEntryStatic.a\",   \"project\", \"$<TARGET_FILE:EcoEntryStatic>\"};\n"
    "inline RuntimeFile embedLib   {\"libEcoEmbedStatic.a\",   \"project\", \"$<TARGET_FILE:EcoEmbedStatic>\"};\n"
    "inline RuntimeFile nodeGlueLib {\"libEcoNodeGlue.a\",    \"project\", \"${ECO_NODE_GLUE_PATH}\"};\n"
    "inline RuntimeFile runtimeLib {\"libEcoRuntimeStatic.a\", \"project\", \"$<TARGET_FILE:EcoRuntimeStatic>\"};\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<RuntimeFile> elmKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_ELM_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "        {\"libElmKernel_${mod}.a\", \"project\", \"$<TARGET_FILE:ElmKernel_${mod}>\"},\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<RuntimeFile> ecoKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "        {\"libEcoKernel_${mod}.a\", \"project\", \"$<TARGET_FILE:EcoKernel_${mod}>\"},\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

# --- LLVM libunwind ------------------------------------------------------
# Passed as an absolute path (not -lunwind) so AOT links never pick up the
# system (nongnu) libunwind. See cmake/LLVMLibunwind.cmake.
get_filename_component(_unwind_base "${LLVM_LIBUNWIND_LIBRARY}" NAME)
string(APPEND ECO_BOOT_CONFIG_CONTENT
    "inline RuntimeFile unwindLib {\"${_unwind_base}\", \"\", \"${LLVM_LIBUNWIND_LIBRARY}\"};\n")
# unwindLibDir: still needed by the non-static glibc-PIE link to set
# -rpath so libunwind.so resolves at AOT-binary runtime. Unused under
# ECO_STATIC* (the .a path doesn't need rpath).
string(APPEND ECO_BOOT_CONFIG_CONTENT
    "inline const char *unwindLibDir = \"${LLVM_LIBUNWIND_LIBRARY_DIR}\";\n\n")

#--- Phase 3: linker + crt paths for direct ld invocation -----------------
# The non-MUSL (glibc/Stage A) profile still uses the legacy absolute-path
# constants. Stage C bundling only applies under ECO_STATIC_MUSL.
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Phase 3: direct-linker config (non-MUSL) ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *systemLinker = \"${ECO_SYSTEM_LD}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *dynamicLinker = \"${ECO_DYNAMIC_LINKER}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crt1Obj = \"${ECO_CRT1_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtiObj = \"${ECO_CRTI_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtnObj = \"${ECO_CRTN_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtbeginObj = \"${ECO_CRTBEGIN_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *crtendObj = \"${ECO_CRTEND_O}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *libgccA = \"${ECO_LIBGCC_A}\";\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline const char *gccLibDir = \"${ECO_GCC_LIBDIR}\";\n\n")

# librarySearchDirs / kernelSystemLibs — needed by the non-MUSL link
# (glibc-PIE) where -lc/-lm/-lstdc++ and -lzip resolve via the linker's
# search path. Unused under ECO_STATIC_MUSL (every dep is absolute), but
# kept so the legacy code path in EcoNativeDriver.cpp still compiles.
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> librarySearchDirs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(_d ${ECO_LIBRARY_DIRS})
    if(_d STREQUAL "")
        continue()
    endif()
    string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"${_d}\",\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<std::string> kernelSystemLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
if(ECO_KERNEL_LIBZIP_FOUND)
    foreach(libzip_entry IN LISTS ECO_KERNEL_LIBZIP_LIBRARIES)
        if(IS_ABSOLUTE "${libzip_entry}")
            string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"${libzip_entry}\",\n")
        else()
            string(APPEND ECO_BOOT_CONFIG_CONTENT "        \"-l${libzip_entry}\",\n")
        endif()
    endforeach()
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

#--- Stage A.5: static-archive paths for AOT-built binaries ----------------
# Vendored libcurl/libssl/libcrypto/libzip/libz under ECO_STATIC — emitted
# as RuntimeFile so the Stage C bundle can carry them too.
if(ECO_STATIC)
    set(ECO_STATIC_BOOL "true")
    _eco_query_clang_path(ECO_LIBSTDCXX_A libstdc++.a)
    find_library(ECO_LIBZ_A z REQUIRED)
    message(STATUS "Eco AOT static-archive paths (ECO_STATIC):")
    message(STATUS "  libstdc++.a: ${ECO_LIBSTDCXX_A}")
    message(STATUS "  libcurl.a:   <vendored: TARGET_FILE:libcurl_static>")
    message(STATUS "  libzip.a:    <vendored: TARGET_FILE:zip>")
    message(STATUS "  libssl.a:    ${OPENSSL_SSL_LIBRARY}")
    message(STATUS "  libcrypto.a: ${OPENSSL_CRYPTO_LIBRARY}")
    message(STATUS "  libz.a:      ${ECO_LIBZ_A}")
else()
    set(ECO_STATIC_BOOL "false")
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Stage A.5: static-archive paths (ECO_STATIC) ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline constexpr bool ecoStatic = ${ECO_STATIC_BOOL};\n")
if(ECO_STATIC)
    # ECO_LIBSTDCXX_A / OPENSSL_*_LIBRARY are absolute file paths; vendored
    # targets ($<TARGET_FILE:...>) resolve at generation time. Compute the
    # basenames for the bundle layout from the absolute paths so the install
    # tree mirrors what eco-boot-native sees at build time.
    get_filename_component(_libstdcxx_name "${ECO_LIBSTDCXX_A}" NAME)
    get_filename_component(_libssl_name "${OPENSSL_SSL_LIBRARY}" NAME)
    get_filename_component(_libcrypto_name "${OPENSSL_CRYPTO_LIBRARY}" NAME)
    get_filename_component(_libz_name "${ECO_LIBZ_A}" NAME)
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile libstdcxxStaticA  {\"${_libstdcxx_name}\", \"\", \"${ECO_LIBSTDCXX_A}\"};\n"
        "inline RuntimeFile libcurlStaticA    {\"libcurl.a\",          \"\", \"$<TARGET_FILE:libcurl_static>\"};\n"
        "inline RuntimeFile libsslStaticA     {\"${_libssl_name}\",    \"\", \"${OPENSSL_SSL_LIBRARY}\"};\n"
        "inline RuntimeFile libcryptoStaticA  {\"${_libcrypto_name}\", \"\", \"${OPENSSL_CRYPTO_LIBRARY}\"};\n"
        "inline RuntimeFile libzipStaticA     {\"libzip.a\",           \"\", \"$<TARGET_FILE:zip>\"};\n"
        "inline RuntimeFile libzStaticA       {\"${_libz_name}\",      \"\", \"${ECO_LIBZ_A}\"};\n")
else()
    # Stubs for the non-static glibc-PIE build path. Never read at runtime
    # when ecoStatic is false; emitted so EcoNativeDriver.cpp compiles.
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile libstdcxxStaticA  {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libcurlStaticA    {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libsslStaticA     {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libcryptoStaticA  {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libzipStaticA     {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libzStaticA       {\"\", \"\", \"\"};\n")
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "\n")

#--- Stage B.5: musl/libc++/compiler-rt symmetric AOT paths ----------------
# Under ECO_STATIC_MUSL the AOT link uses the same musl/libc++/compiler-rt
# stack as the eco binary itself. Each path is a RuntimeFile carrying its
# build-time absolute path (for eco-boot-native during the build) and the
# bundle layout basename + subdir (for the installed eco binary).
if(ECO_STATIC_MUSL)
    set(ECO_STATIC_MUSL_BOOL "true")
else()
    set(ECO_STATIC_MUSL_BOOL "false")
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Stage B.5: musl/libc++/compiler-rt paths (ECO_STATIC_MUSL) ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "inline constexpr bool ecoStaticMusl = ${ECO_STATIC_MUSL_BOOL};\n")
if(ECO_STATIC_MUSL)
    # Compute basenames once for the install tree.
    get_filename_component(_libcxx_name "${ECO_LIBCXX_A}" NAME)
    get_filename_component(_libcxxabi_name "${ECO_LIBCXXABI_A}" NAME)
    get_filename_component(_compilerrt_name "${ECO_COMPILER_RT_BUILTINS_A}" NAME)
    get_filename_component(_libc_name "${ECO_LIBC_A}" NAME)
    get_filename_component(_crt1_name "${ECO_CRT1_O_STATIC}" NAME)
    get_filename_component(_crtbegin_name "${ECO_CRTBEGIN_O_STATIC}" NAME)
    get_filename_component(_crtend_name "${ECO_CRTEND_O_STATIC}" NAME)
    get_filename_component(_crti_name "${ECO_CRTI_O}" NAME)
    get_filename_component(_crtn_name "${ECO_CRTN_O}" NAME)
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile libcStaticA         {\"${_libc_name}\",       \"\",    \"${ECO_LIBC_A}\"};\n"
        "inline RuntimeFile libcxxStaticA       {\"${_libcxx_name}\",     \"\",    \"${ECO_LIBCXX_A}\"};\n"
        "inline RuntimeFile libcxxabiStaticA    {\"${_libcxxabi_name}\",  \"\",    \"${ECO_LIBCXXABI_A}\"};\n"
        "inline RuntimeFile compilerRtBuiltinsA {\"${_compilerrt_name}\", \"\",    \"${ECO_COMPILER_RT_BUILTINS_A}\"};\n"
        "inline RuntimeFile crt1ObjStatic       {\"${_crt1_name}\",       \"crt\", \"${ECO_CRT1_O_STATIC}\"};\n"
        "inline RuntimeFile crtiObjStatic       {\"${_crti_name}\",       \"crt\", \"${ECO_CRTI_O}\"};\n"
        "inline RuntimeFile crtnObjStatic       {\"${_crtn_name}\",       \"crt\", \"${ECO_CRTN_O}\"};\n"
        "inline RuntimeFile crtbeginObjStatic   {\"${_crtbegin_name}\",   \"crt\", \"${ECO_CRTBEGIN_O_STATIC}\"};\n"
        "inline RuntimeFile crtendObjStatic     {\"${_crtend_name}\",     \"crt\", \"${ECO_CRTEND_O_STATIC}\"};\n"
        "inline RuntimeFile bundledLinker       {\"ld.lld\",              \"\",    \"${ECO_BUILD_LD_LLD}\"};\n")
else()
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile libcStaticA         {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libcxxStaticA       {\"\", \"\", \"\"};\n"
        "inline RuntimeFile libcxxabiStaticA    {\"\", \"\", \"\"};\n"
        "inline RuntimeFile compilerRtBuiltinsA {\"\", \"\", \"\"};\n"
        "inline RuntimeFile crt1ObjStatic       {\"\", \"\", \"\"};\n"
        "inline RuntimeFile crtiObjStatic       {\"\", \"\", \"\"};\n"
        "inline RuntimeFile crtnObjStatic       {\"\", \"\", \"\"};\n"
        "inline RuntimeFile crtbeginObjStatic   {\"\", \"\", \"\"};\n"
        "inline RuntimeFile crtendObjStatic     {\"\", \"\", \"\"};\n"
        "inline RuntimeFile bundledLinker       {\"\", \"\", \"\"};\n")
endif()
string(APPEND ECO_BOOT_CONFIG_CONTENT "\n")

#--- Stage D: glibc output-profile inputs (bundle-only) ---------------------
# Consumed by the GlibcBundleShared link profile in EcoNativeDriver.cpp when
# the installed bundle carries lib/eco-runtime/glibc/. buildPath is empty in
# EVERY build flavor: the Alpine configure cannot see the Debian-built
# archives, the dev build never takes this profile, and resolveFile()'s
# bundle resolution ($ECO_RUNTIME_DIR / exe-relative) is the only mechanism
# that can supply these files. Emitted unconditionally — basenames and
# subdirs are static — so the driver compiles in all configurations.
# See plans/stage-d-hybrid-link-profiles.md (steps 4-5).
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Stage D: glibc output-profile inputs (bundle-only) ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT
    "inline RuntimeFile glibcCrtiObj     {\"crti.o\",      \"glibc/crt\", \"\"};\n"
    "inline RuntimeFile glibcCrtnObj     {\"crtn.o\",      \"glibc/crt\", \"\"};\n"
    "inline RuntimeFile glibcCrtbeginObj {\"crtbeginS.o\", \"glibc/crt\", \"\"};\n"
    "inline RuntimeFile glibcCrtendObj   {\"crtendS.o\",   \"glibc/crt\", \"\"};\n"
    "inline RuntimeFile glibcLibcxxA     {\"libc++.a\",    \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcLibcxxabiA  {\"libc++abi.a\", \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcUnwindA     {\"libunwind.a\", \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcBuiltinsA   {\"libclang_rt.builtins-x86_64.a\", \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcLibcNonsharedA {\"libc_nonshared.a\", \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcCurlA       {\"libcurl.a\",   \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcSslA        {\"libssl.a\",    \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcCryptoA     {\"libcrypto.a\", \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcZipA        {\"libzip.a\",    \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcZA          {\"libz.a\",      \"glibc\", \"\"};\n"
    "inline RuntimeFile glibcEmbedLib    {\"libEcoEmbedStatic.a\",   \"glibc/project\", \"\"};\n"
    "inline RuntimeFile glibcNodeGlueLib {\"libEcoNodeGlue.a\",      \"glibc/project\", \"\"};\n"
    "inline RuntimeFile glibcRuntimeLib  {\"libEcoRuntimeStatic.a\", \"glibc/project\", \"\"};\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<RuntimeFile> glibcElmKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_ELM_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "        {\"libElmKernel_${mod}.a\", \"glibc/project\", \"\"},\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

string(APPEND ECO_BOOT_CONFIG_CONTENT "inline std::vector<RuntimeFile> glibcEcoKernelLibs() {\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "    return {\n")
foreach(mod ${ECO_KERNEL_MODS})
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "        {\"libEcoKernel_${mod}.a\", \"glibc/project\", \"\"},\n")
endforeach()
string(APPEND ECO_BOOT_CONFIG_CONTENT "    };\n}\n\n")

#--- Phase 3 (Darwin): AOT link driver config ------------------------------
# Consumed by linkExecutableDarwin() in EcoNativeDriver.cpp. Empty strings
# on non-Darwin builds; the non-Darwin code paths never read them.
#
# darwinClang is configured-time absolute (xcrun -f clang) on Darwin; for
# the installed bundle it falls back to xcrun (PATH-resolved by the OS)
# since users may not have the same Xcode prefix as the build host.
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Phase 3 (Darwin): AOT link driver config ---\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT
    "inline const char *darwinClang             = \"${ECO_DARWIN_CLANG}\";\n"
    "inline const char *darwinSdkRoot           = \"${ECO_DARWIN_SDK_ROOT}\";\n"
    "inline const char *darwinArch              = \"${ECO_DARWIN_ARCH}\";\n"
    "inline RuntimeFile darwinLibzipA           {\"libzip.a\",    \"project\", \"${ECO_DARWIN_LIBZIP_A}\"};\n"
    "inline RuntimeFile darwinLibsslA           {\"libssl.a\",    \"project\", \"${ECO_DARWIN_LIBSSL_A}\"};\n"
    "inline RuntimeFile darwinLibcryptoA        {\"libcrypto.a\", \"project\", \"${ECO_DARWIN_LIBCRYPTO_A}\"};\n\n")

# --- W4 (Win64): AOT link driver config ---
# The three vendored static libs the user-program link line consumes:
# libcurl_static (with schannel TLS), zip (libzip), zlibstatic. Paths are
# wrapped in generator expressions so they resolve to the actual built .lib
# after the FetchContent targets land. The RuntimeFile basenames match how
# the bundle (W4 #19) ships them.
string(APPEND ECO_BOOT_CONFIG_CONTENT "// --- Phase 3 (Win64): AOT link driver config ---\n")
if(WIN32)
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile windowsLibcurlA  {\"libcurl_static.lib\", \"project\", \"$<TARGET_FILE:libcurl_static>\"};\n"
        "inline RuntimeFile windowsLibzipA   {\"zip.lib\",            \"project\", \"$<TARGET_FILE:zip>\"};\n"
        "inline RuntimeFile windowsZlibA     {\"zlibstatic.lib\",     \"project\", \"$<TARGET_FILE:zlibstatic>\"};\n\n")
else()
    string(APPEND ECO_BOOT_CONFIG_CONTENT
        "inline RuntimeFile windowsLibcurlA  {\"\", \"\", \"\"};\n"
        "inline RuntimeFile windowsLibzipA   {\"\", \"\", \"\"};\n"
        "inline RuntimeFile windowsZlibA     {\"\", \"\", \"\"};\n\n")
endif()

string(APPEND ECO_BOOT_CONFIG_CONTENT "} // namespace config\n")
string(APPEND ECO_BOOT_CONFIG_CONTENT "} // namespace eco\n")

file(GENERATE
    OUTPUT "${ECO_BOOT_CONFIG_HEADER}"
    CONTENT "${ECO_BOOT_CONFIG_CONTENT}"
)

if(NOT ECO_GLIBC_OUTPUT_RUNTIME) # MLIR half: the eco-boot-native CLI

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
set(ECO_BOOT_NATIVE_RUNTIME_DEPS EcoEntryStatic EcoEmbedStatic EcoRuntimeStatic)
if(TARGET EcoNodeGlue)
    list(APPEND ECO_BOOT_NATIVE_RUNTIME_DEPS EcoNodeGlue)
endif()
foreach(mod ${ECO_ELM_KERNEL_MODS})
    list(APPEND ECO_BOOT_NATIVE_RUNTIME_DEPS ElmKernel_${mod})
endforeach()
foreach(mod ${ECO_KERNEL_MODS})
    list(APPEND ECO_BOOT_NATIVE_RUNTIME_DEPS EcoKernel_${mod})
endforeach()
add_dependencies(eco-boot-native ${ECO_BOOT_NATIVE_RUNTIME_DEPS})

target_compile_features(eco-boot-native PRIVATE cxx_std_20)
target_compile_options(eco-boot-native PRIVATE -Wno-ambiguous-reversed-operator $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
if(ECO_LOWERING_VALIDATION)
    target_compile_definitions(eco-boot-native PRIVATE ECO_LOWERING_VALIDATION=1)
endif()

endif() # NOT ECO_GLIBC_OUTPUT_RUNTIME — eco-boot-native CLI

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
