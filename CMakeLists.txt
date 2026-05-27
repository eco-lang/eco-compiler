cmake_minimum_required(VERSION 3.20)
project(EcoRuntime LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
include(LLVMLibunwind)

# Runtime GC debug assertions: default ON for Debug builds, OFF for Release.
# Declared at top level so EVERY target that includes the allocator headers
# (NurserySpace, ThreadLocalHeap, Allocator) sees the same value of
# ECO_GC_DEBUG. The headers conditionally add a member (`in_minor_gc_`) under
# this macro, so any inconsistency causes an ODR/ABI mismatch between
# libraries and the test binary.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" ON)
else()
    option(ECO_GC_DEBUG "Enable runtime GC debug checks (nursery stale-pointer detection)" OFF)
endif()
if(ECO_GC_DEBUG)
    add_compile_definitions(ECO_GC_DEBUG=1)
endif()

# Validation-only switch for verifier passes (e.g. EcoBoxedStoreVerify,
# EcoPtrIntVerify, the GC liveness audit) AND extra runtime barriers in
# kernel/allocator copy loops that don't go through the hooked
# eco_store_field path. Independent of ECO_GC_DEBUG. Default OFF
# regardless of build type — slow.
option(ECO_LOWERING_VALIDATION
       "Enable validation-only verifier passes and runtime copy-loop barriers (slow)"
       OFF)
if(ECO_LOWERING_VALIDATION)
    add_compile_definitions(ECO_LOWERING_VALIDATION=1)
endif()

# Heap-validator switch. Independent of ECO_GC_DEBUG and
# ECO_LOWERING_VALIDATION. Enables the always-on stale-HPointer detection
# (write/read/arg-side hooks, free-region poisoning), the per-container
# bitmap-mismatch tripwires, the post-GC heap-integrity walker, the
# from-space pre-evacuation walk, the forward-chain-depth assert, and the
# old-gen / BBoP invariant audits. Off by default — these are hot-path
# checks. Turn on for diagnostic runs (heap-profile, stress).
option(ECO_HEAP_VALIDATE
       "Enable heap corruption detectors at every read/write/GC-walk site (slow)"
       OFF)
if(ECO_HEAP_VALIDATE)
    add_compile_definitions(ECO_HEAP_VALIDATE=1)
endif()

# Per-GC `[heap-trace] …` diagnostics. When OFF (default), the trace prints
# and their gathering logic are compiled out so they cost nothing on the hot
# path. When ON, the existing `ECO_HEAP_TRACE` env-var still gates emission at
# runtime — set `ECO_HEAP_TRACE=1` to actually see output.
option(ECO_HEAP_TRACE
       "Compile in per-GC [heap-trace] diagnostics (still gated by ECO_HEAP_TRACE env var)"
       OFF)
if(ECO_HEAP_TRACE)
    add_compile_definitions(ECO_HEAP_TRACE=1)
endif()

add_executable(ecor
        runtime/src/main.cpp
        runtime/src/allocator/RootSet.cpp
        runtime/src/allocator/HeapConfigJson.cpp
        runtime/src/allocator/OldGenSpace.cpp
        runtime/src/allocator/NurserySpace.cpp
        runtime/src/allocator/Allocator.cpp
        runtime/src/allocator/ThreadLocalHeap.cpp
        runtime/src/allocator/GCStats.cpp
        runtime/src/allocator/StackMap.cpp
        runtime/src/allocator/StackUnwind.cpp
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

# libunwind for stack unwinding in GC root scanning — specifically LLVM's
# libunwind (from LLVM_ENABLE_RUNTIMES); see cmake/LLVMLibunwind.cmake.
target_link_libraries(ecor PRIVATE eco::llvm_libunwind)

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

# All Elm-tooling caches (eco-stuff/, elm-stuff/, bin/) now live under
# ${CMAKE_BINARY_DIR}/compiler/build-{xhr,kernel}/ and
# ${CMAKE_BINARY_DIR}/test/<pkg>/, shadowed in via the configure-time scaffolding
# in compiler/CMakeLists.txt and test/CMakeLists.txt. `rm -rf build/` resets
# everything; `ninja clean` removes ninja-tracked outputs but leaves the
# compiler's runtime caches alone — that's fine, the bootstrap chain and the
# Stage 5 stale-.ecot sweep handle staleness themselves.

# Convenience targets for common workflows.

# Usage: cmake --build build --target rebuild
add_custom_target(rebuild
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMENT "Clean, rebuild all targets"
    USES_TERMINAL
)

# Usage: cmake --build build --target check
# Usage with filter: TEST_FILTER=elm cmake --build build --target check
#
# Gate A in guides/bootstrap.md: build the default ALL graph (which
# includes Stage 1 / guida) and run the JIT E2E suite. The JIT runner
# compiles each Elm test through Stage 1's `compiler/bin/index.js`
# (guida.js via the XHR mock + eco-io-handler), so only Stage 1 is
# needed — no Stage 2+ build.
add_custom_target(check
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Gate A (incremental): build default ALL + Stage 1, run JIT E2E"
    USES_TERMINAL
)

# Usage: cmake --build build --target run-tests
# Usage with filter: TEST_FILTER=elm cmake --build build --target run-tests
add_custom_target(run-tests
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Run tests (no build)"
    USES_TERMINAL
)

# Usage: cmake --build build --target stress
# Usage with filter: TEST_FILTER=reverse cmake --build build --target stress
# Runs the separate stress-test binary (longer/larger Elm programs).
add_custom_target(stress
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target stress-test
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/stress-test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Build and run Elm stress tests"
    USES_TERMINAL
)

# Usage: cmake --build build --target full
# Usage with filter: TEST_FILTER=elm cmake --build build --target full
#
# Gate A in guides/bootstrap.md (from-clean): clean, rebuild the default
# ALL graph (which includes Stage 1 / guida), then run the JIT E2E suite.
# The JIT runner compiles each Elm test through Stage 1's
# `compiler/bin/index.js` (guida.js via the XHR mock + eco-io-handler),
# so only Stage 1 is needed — no Stage 2+ build.
add_custom_target(full
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    COMMENT "Gate A: clean, rebuild default ALL + Stage 1, run JIT E2E"
    USES_TERMINAL
)
