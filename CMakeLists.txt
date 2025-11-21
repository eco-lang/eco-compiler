cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES CXX)

add_executable(ecor
        runtime/src/main.cpp
        runtime/src/RootSet.cpp
        runtime/src/OldGenSpace.cpp
        runtime/src/NurserySpace.cpp
        runtime/src/GarbageCollector.cpp
        runtime/src/gc_stats.cpp
        test/generators.hpp
)

target_include_directories(ecor PRIVATE runtime/include)
target_compile_features(ecor PRIVATE cxx_std_20)

# Link RapidCheck
find_package(rapidcheck REQUIRED)
target_link_libraries(ecor PRIVATE rapidcheck)

# Add pthread for threading support
find_package(Threads REQUIRED)
target_link_libraries(ecor PRIVATE Threads::Threads)

add_subdirectory(test)