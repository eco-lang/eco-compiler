cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES CXX)

add_executable(ecor
        runtime/src/main.cpp
        runtime/src/RootSet.cpp
        runtime/src/OldGenSpace.cpp
        runtime/src/NurserySpace.cpp
        runtime/src/Allocator.cpp
        runtime/src/ThreadLocalHeap.cpp
        runtime/src/GCStats.cpp
        test/HeapGenerators.hpp
)

target_include_directories(ecor PRIVATE runtime/include)
target_compile_features(ecor PRIVATE cxx_std_20)

# Keep asserts enabled even in release builds for debugging
target_compile_options(ecor PRIVATE -UNDEBUG)

# Include debug symbols for stack traces (works with release optimization)
target_compile_options(ecor PRIVATE -g)

# Link RapidCheck
find_package(rapidcheck REQUIRED)
target_link_libraries(ecor PRIVATE rapidcheck)

# Add pthread for threading support
find_package(Threads REQUIRED)
target_link_libraries(ecor PRIVATE Threads::Threads)

# Export symbols for stack traces (enables function names in backtrace)
target_link_options(ecor PRIVATE -rdynamic)

add_subdirectory(test)