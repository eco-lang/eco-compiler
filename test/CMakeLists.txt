include_directories(../runtime/include/)

add_executable(test
        main.cpp
        generators.cpp
        ../runtime/src/allocator.cpp
)

target_compile_features(test PRIVATE cxx_std_20)

target_link_libraries(test rapidcheck)
