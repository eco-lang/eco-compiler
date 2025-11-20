include_directories(../runtime/include/)

add_executable(test
        main.cpp
        generators.cpp
        allocator_test.cpp
        ../runtime/src/allocator.cpp
        ../runtime/src/gc_stats.cpp
)

target_compile_features(test PRIVATE cxx_std_20)

target_link_libraries(test rapidcheck)

# Object pool unit tests
add_executable(object_pool_test
        object_pool_test.cpp
)

target_compile_features(object_pool_test PRIVATE cxx_std_20)

# Simple object pool test
add_executable(object_pool_simple_test
        object_pool_simple_test.cpp
)

target_compile_features(object_pool_simple_test PRIVATE cxx_std_20)
