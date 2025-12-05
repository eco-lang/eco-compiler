include_directories(../runtime/src/allocator/)
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

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
        ../runtime/src/allocator/RootSet.cpp
        ../runtime/src/allocator/OldGenSpace.cpp
        ../runtime/src/allocator/NurserySpace.cpp
        ../runtime/src/allocator/Allocator.cpp
        ../runtime/src/allocator/ThreadLocalHeap.cpp
        ../runtime/src/allocator/GCStats.cpp
        ../runtime/src/allocator/StringOps.cpp
        ../runtime/src/allocator/ListOps.cpp
        ../runtime/src/allocator/BytesOps.cpp
)

target_compile_features(test PRIVATE cxx_std_20)
target_link_libraries(test rapidcheck)
