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
        allocator/AllocatorTest.cpp
        allocator/AllocatorCommonTest.cpp
        allocator/ElmTest.cpp
        allocator/HeapHelpersTest.cpp
        allocator/StringOpsTest.cpp
        allocator/ListOpsTest.cpp
        allocator/BytesOpsTest.cpp
        allocator/RuntimeExportsTest.cpp
)

target_compile_features(test PRIVATE cxx_std_20)
target_compile_options(test PRIVATE -fexceptions)
# Use --whole-archive for EcoRunner so that Scheduler/PlatformRuntime symbols
# are available when ElmKernel transitive dependencies are processed by the linker.
target_link_libraries(test rapidcheck -Wl,--whole-archive EcoRunner -Wl,--no-whole-archive)
