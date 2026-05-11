include_directories(../runtime/src/allocator/)
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# Find MLIR for codegen tests (EcoRunner depends on it)
find_package(MLIR REQUIRED CONFIG)
list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include_directories(${LLVM_INCLUDE_DIRS})
include_directories(${MLIR_INCLUDE_DIRS})
add_definitions(${LLVM_DEFINITIONS})

# Include codegen headers (for EcoRunner)
include_directories(../runtime/src/codegen)
include_directories(${CMAKE_BINARY_DIR}/runtime/src/codegen/include)

# Note: Allocator sources (Allocator.cpp, NurserySpace.cpp, etc.) are NOT included here
# because they are already compiled into the EcoRunner library. This ensures there's
# only one Allocator singleton so GC stats accumulate correctly across all tests.
add_executable(test
        main.cpp
        allocator/HeapGenerators.cpp
        allocator/TestHelpers.cpp
        allocator/NurserySpaceTest.cpp
        allocator/OldGenSpaceTest.cpp
        allocator/OldGenCapacityTest.cpp
        allocator/OldGenHeapBaseSentinelTest.cpp
        allocator/OldGenLazySweepTest.cpp
        allocator/OldGenSweepOnDemandTest.cpp
        allocator/OldGenSweepBudgetTest.cpp
        allocator/OldGenSmallClassBudgetTest.cpp
        allocator/AllocatorTest.cpp
        allocator/AllocatorCommonTest.cpp
        allocator/ElmTest.cpp
        allocator/HeapHelpersTest.cpp
        allocator/StringOpsTest.cpp
        allocator/ListOpsTest.cpp
        allocator/BytesOpsTest.cpp
        allocator/RuntimeExportsTest.cpp
        allocator/GenericApplyBoxingTest.cpp
        allocator/EcoApplyClosureTypedTest.cpp
        allocator/GCPressureTest.cpp
)

target_compile_features(test PRIVATE cxx_std_20)
target_compile_options(test PRIVATE -fexceptions)
# Use --whole-archive for EcoRunner so that Scheduler/PlatformRuntime symbols
# are available when ElmKernel transitive dependencies are processed by the linker.
#
# Also whole-archive EcoKernel_MVar + EcoKernel_Runtime so the JIT's
# DynamicLibrarySearchGenerator can dlsym the `Eco_Kernel_MVar_*` kernel
# symbols (test/eco-kernel E2E suite drives the MVar kernel directly).
target_link_libraries(test rapidcheck
    -Wl,--whole-archive
        EcoRunner
        EcoKernel_MVar
        EcoKernel_Runtime
    -Wl,--no-whole-archive
)
# Export symbols so the JIT can find them via dlsym.
set_target_properties(test PROPERTIES ENABLE_EXPORTS ON)

# Stress test runner — a separate binary so these can be built/run independently
# of the main E2E suite. Reuses ElmE2ETestBase/TestSuite/IsolatedTestRunner.
add_executable(stress-test
        stress-elm/main.cpp
)
target_compile_features(stress-test PRIVATE cxx_std_20)
target_compile_options(stress-test PRIVATE -fexceptions)
# Mirror the kernel wiring on stress-test so stress-elm MVar cases work.
target_link_libraries(stress-test
    -Wl,--whole-archive
        EcoRunner
        EcoKernel_MVar
        EcoKernel_Runtime
    -Wl,--no-whole-archive
)
set_target_properties(stress-test PROPERTIES ENABLE_EXPORTS ON)

# mlir-equivalence — compares Stage 2 (eco-boot.js) vs Stage 6 (eco-compiler
# native ELF) MLIR output across all Elm E2E test sources. Opt-in: requires
# the bootstrap chain through Stage 6 to be built first. `run-mlir-equivalence`
# DEPENDS on the relevant bootstrap outputs so a clean+run sequence rebuilds
# them automatically; the binary itself still preflights at startup and aborts
# with a diagnostic if anything is missing.
#
# Usage:
#     cmake --build build --target mlir-equivalence     # builds the binary
#     cmake --build build --target run-mlir-equivalence # builds + runs the suite
#     TEST_FILTER=Record cmake --build build --target run-mlir-equivalence
add_executable(mlir-equivalence
        mlir_equivalence_main.cpp
)
target_compile_features(mlir-equivalence PRIVATE cxx_std_20)
target_compile_options(mlir-equivalence PRIVATE -fexceptions)
target_compile_definitions(mlir-equivalence PRIVATE
        REPO_ROOT="${CMAKE_SOURCE_DIR}"
)

# `cmake --build build --target clean` should drop the per-run output tree
# (binary .mlir files and per-test --builddir scratch) alongside the regular
# object files. The directory is created on demand by the runner.
set_property(DIRECTORY APPEND PROPERTY
        ADDITIONAL_CLEAN_FILES "${CMAKE_BINARY_DIR}/test/mlir-equivalence-out"
)

# The three bootstrap outputs the runner needs at runtime. Listed as file
# dependencies (not target names) because `compiler/` is added after `test/`
# in the top-level CMakeLists, so the eco-boot / eco-compiler target names
# aren't yet visible here — file-level dependencies are resolved later, once
# both add_subdirectory calls have been processed.
set(MLIR_EQUIV_BOOTSTRAP_DEPS
        "${CMAKE_SOURCE_DIR}/compiler/build-kernel/bin/eco-boot.js"
        "${CMAKE_SOURCE_DIR}/compiler/build-kernel/bin/eco-boot-runner.js"
        "${CMAKE_SOURCE_DIR}/compiler/build-kernel/bin/eco-compiler"
)

add_custom_target(run-mlir-equivalence
        COMMAND sh -c "$<TARGET_FILE:mlir-equivalence> $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
        DEPENDS mlir-equivalence ${MLIR_EQUIV_BOOTSTRAP_DEPS}
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        USES_TERMINAL
        COMMENT "Running Stage 2 vs Stage 6 MLIR equivalence tests"
)
