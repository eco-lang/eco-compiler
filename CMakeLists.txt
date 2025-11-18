cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES CXX)

# Try to find RapidCheck
find_package(rapidcheck QUIET)

if(rapidcheck_FOUND)
    add_executable(gc_test
        src/main.cpp
        src/allocator.cpp
    )

    target_include_directories(gc_test PRIVATE src)
    target_compile_features(gc_test PRIVATE cxx_std_20)

    # Link RapidCheck
    target_link_libraries(gc_test PRIVATE rapidcheck)

    # Add pthread for threading support
    find_package(Threads REQUIRED)
    target_link_libraries(gc_test PRIVATE Threads::Threads)

    message(STATUS "RapidCheck found - gc_test target enabled")
else()
    message(STATUS "RapidCheck not found - gc_test target disabled")
    message(STATUS "To install RapidCheck: git clone https://github.com/emil-e/rapidcheck && cd rapidcheck && mkdir build && cd build && cmake .. && make && sudo make install")
endif()
