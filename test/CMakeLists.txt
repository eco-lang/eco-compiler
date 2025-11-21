include_directories(../runtime/include/)

add_executable(test
        main.cpp
        HeapGenerators.cpp
        GarbageCollectorTest.cpp
        TLABTest.cpp
        OldGenSpaceTest.cpp
        CompactionTest.cpp
        ../runtime/src/RootSet.cpp
        ../runtime/src/OldGenSpace.cpp
        ../runtime/src/NurserySpace.cpp
        ../runtime/src/GarbageCollector.cpp
        ../runtime/src/GCStats.cpp
)

target_compile_features(test PRIVATE cxx_std_20)
target_link_libraries(test rapidcheck)
