cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES C CXX)

add_executable(ecor
        runtime/src/main.cpp
        runtime/src/allocator/RootSet.cpp
        runtime/src/allocator/OldGenSpace.cpp
        runtime/src/allocator/NurserySpace.cpp
        runtime/src/allocator/Allocator.cpp
        runtime/src/allocator/ThreadLocalHeap.cpp
        runtime/src/allocator/GCStats.cpp
        runtime/src/allocator/StackMap.cpp
        test/allocator/HeapGenerators.hpp
)

target_include_directories(ecor PRIVATE runtime/src/allocator)
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

# MLIR-based code generation
add_subdirectory(runtime/src/codegen)

# Elm kernel C++ implementation
add_subdirectory(elm-kernel-cpp)

# Eco kernel C++ implementation (IO operations)
add_subdirectory(eco-kernel-cpp)

# Guida compiler (Elm compiler written in Elm)
add_subdirectory(compiler)

# Clean target support - mark eco-stuff directories for cleaning
# Note: ADDITIONAL_CLEAN_FILES is the modern name (CMake 3.15+), ADDITIONAL_MAKE_CLEAN_FILES
# is the legacy name. Both are set for maximum compatibility.
set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_CLEAN_FILES
    "${CMAKE_SOURCE_DIR}/test/elm/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-bytes/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-core/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-http/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-json/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-regex/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-time/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-url/eco-stuff"
    "${CMAKE_SOURCE_DIR}/compiler/examples/eco-stuff"
)
set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES
    "${CMAKE_SOURCE_DIR}/test/elm/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-bytes/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-core/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-http/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-json/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-regex/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-time/eco-stuff"
    "${CMAKE_SOURCE_DIR}/test/elm-url/eco-stuff"
    "${CMAKE_SOURCE_DIR}/compiler/examples/eco-stuff"
)

# Convenience targets for common workflows
# Usage: cmake --build build --target rebuild
add_custom_target(rebuild
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-bytes/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-core/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-http/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-json/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-regex/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-time/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-url/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/compiler/examples/eco-stuff"
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMENT "Clean eco-stuff, rebuild all targets"
    USES_TERMINAL
)

# Usage: cmake --build build --target check
# Usage with filter: TEST_FILTER=elm cmake --build build --target check
add_custom_target(check
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Build and run tests"
    USES_TERMINAL
)

# Usage: cmake --build build --target run-tests
# Usage with filter: TEST_FILTER=elm cmake --build build --target run-tests
add_custom_target(run-tests
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Run tests (no build)"
    USES_TERMINAL
)

# Usage: cmake --build build --target full
# Usage with filter: TEST_FILTER=elm cmake --build build --target full
add_custom_target(full
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-bytes/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-core/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-http/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-json/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-regex/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-time/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/test/elm-url/eco-stuff"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_SOURCE_DIR}/compiler/examples/eco-stuff"
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Clean eco-stuff, rebuild, and run tests"
    USES_TERMINAL
)
