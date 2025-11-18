cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES CXX)

add_executable(gc_test
        src/main.cpp
        src/allocator.cpp
)

target_include_directories(gc_test PRIVATE src)
target_compile_features(gc_test PRIVATE cxx_std_20)

# Link RapidCheck
find_package(rapidcheck REQUIRED)
target_link_libraries(gc_test PRIVATE rapidcheck)

# Add pthread for threading support
find_package(Threads REQUIRED)
target_link_libraries(gc_test PRIVATE Threads::Threads)

