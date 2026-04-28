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
        allocator/AllocatorTest.cpp
        allocator/AllocatorCommonTest.cpp
        allocator/ElmTest.cpp
        allocator/HeapHelpersTest.cpp
        allocator/StringOpsTest.cpp
        allocator/ListOpsTest.cpp
        allocator/BytesOpsTest.cpp
        allocator/RuntimeExportsTest.cpp
        allocator/GenericApplyBoxingTest.cpp
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
