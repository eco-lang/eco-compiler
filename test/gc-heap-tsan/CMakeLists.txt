# threaded-gc-05c Step 8 (plans/threaded-gc-05c-concurrent-marking.md D9): the
# REAL allocator under ThreadSanitizer, driven by a synthetic mutator with
# concurrent marking on (conc_mark = 2). A STANDALONE project built with g++
# (clang 14 here has no TSan runtime). Stack unwinding is stubbed: the driver
# roots everything through the RootSet, so no stack-map frame is needed.
#
#   cmake -S test/gc-heap-tsan -B build-heap-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
#   cmake --build build-heap-tsan && timeout 3600 build-heap-tsan/gc-heap-tsan
#
# Pass: "heap_driver PASS", exit 0, no "WARNING: ThreadSanitizer".
#
# -DECO_TLA_TRACE=ON builds the TLA+ trace harness gc-heap-trace INSTEAD (no
# TSan: trace builds and TSan builds are separate, parent plan §6.3), with the
# runtime's ECO_TLA_TRACE hooks compiled in and test/tla/trace/TlaTrace.cpp
# linked. test/tla/run_traces.py configures, builds and runs it (tla-trace).
cmake_minimum_required(VERSION 3.20)
project(gc_heap_tsan CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(ECO_TLA_TRACE "Build the TLA+ trace harness (gc-heap-trace) instead of the TSan one" OFF)
set(ECO_ALLOC ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src/allocator)
file(GLOB ECO_ALLOC_SRC ${ECO_ALLOC}/*.cpp)
list(FILTER ECO_ALLOC_SRC EXCLUDE REGEX "(PlatformVirtualMemory_win32|StackUnwind)\\.cpp$")
find_package(Threads REQUIRED)
if(NOT ECO_TLA_TRACE)
add_executable(gc-heap-tsan heap_driver.cpp promo_sweep.cpp ylos_sweep.cpp cr012_two_heap.cpp stub_unwind.cpp ${ECO_ALLOC_SRC})
target_include_directories(gc-heap-tsan PRIVATE ${ECO_ALLOC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../elm-kernel-cpp/vendor)
target_compile_definitions(gc-heap-tsan PRIVATE ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1)
target_compile_options(gc-heap-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG -Wno-tsan)
target_link_options(gc-heap-tsan PRIVATE -fsanitize=thread)
target_link_libraries(gc-heap-tsan PRIVATE Threads::Threads)
else()
add_executable(gc-heap-trace heap_driver.cpp tiny_graph.cpp tiny_tenure.cpp promo_sweep.cpp stub_unwind.cpp ${ECO_ALLOC_SRC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-heap-trace PRIVATE ${ECO_ALLOC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../elm-kernel-cpp/vendor)
target_compile_definitions(gc-heap-trace PRIVATE ECO_TLA_TRACE=1 ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1)
target_compile_options(gc-heap-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-heap-trace PRIVATE Threads::Threads)
endif()

# TLA+ model M6 (plans/threaded-gc-tla-M6-lifecycle.md §8; register CR-008): the fork
# harness, fork_harness.cpp. The real allocator with asserts and validation on, NOT under
# TSan (TSan does not support fork in a threaded process). Not built by default:
#   cmake --build build-heap-tsan --target gc-fork-harness
#   build-heap-tsan/gc-fork-harness <arm> [trials [seed]]          (README.md, "Fork harness")
# With -DECO_TLA_TRACE=ON the same file builds gc-fork-trace, M6's gang trace harness
# (test/tla/M6-lifecycle/TraceGangs.tla), run by test/tla/run_traces.py.
if(NOT ECO_TLA_TRACE)
add_executable(gc-fork-harness EXCLUDE_FROM_ALL fork_harness.cpp stub_unwind.cpp ${ECO_ALLOC_SRC})
target_include_directories(gc-fork-harness PRIVATE ${ECO_ALLOC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../elm-kernel-cpp/vendor)
target_compile_definitions(gc-fork-harness PRIVATE ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1)
target_compile_options(gc-fork-harness PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-fork-harness PRIVATE Threads::Threads)
# The register guards (fork_arms.txt, run_fork_arms.py; plans/threaded-gc-register-repros-impl.md
# Step 27): this flavour's rows. Not in ALL; the arms fork and abort by design.
add_custom_target(fork-det
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/run_fork_arms.py --tier quick --flavor plain
            --exe $<TARGET_FILE:gc-fork-harness> --build-dir ${CMAKE_CURRENT_BINARY_DIR}/fork-det
    DEPENDS gc-fork-harness USES_TERMINAL VERBATIM)
# The deterministic TSan race arms of the register (fork_arms.txt, flavour tsan).
add_custom_target(tsan-det
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/run_fork_arms.py --tier quick --flavor tsan
            --exe $<TARGET_FILE:gc-heap-tsan> --build-dir ${CMAKE_CURRENT_BINARY_DIR}/tsan-det
    DEPENDS gc-heap-tsan USES_TERMINAL VERBATIM)
else()
# TlaTrace.cpp FIRST: its statics are then constructed first and destroyed last, so a
# forked child's exit() can run ~Allocator (whose hooks call tlatrace::wants) while
# recording (det-cr013-*-exit, det-cr031).
add_executable(gc-fork-trace EXCLUDE_FROM_ALL ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp
    fork_harness.cpp stub_unwind.cpp ${ECO_ALLOC_SRC})
target_include_directories(gc-fork-trace PRIVATE ${ECO_ALLOC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../elm-kernel-cpp/vendor)
target_compile_definitions(gc-fork-trace PRIVATE ECO_TLA_TRACE=1 ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1)
target_compile_options(gc-fork-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-fork-trace PRIVATE Threads::Threads)
add_custom_target(fork-det
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/run_fork_arms.py --tier quick --flavor trace
            --exe $<TARGET_FILE:gc-fork-trace> --build-dir ${CMAKE_CURRENT_BINARY_DIR}/fork-det
    DEPENDS gc-fork-trace USES_TERMINAL VERBATIM)
endif()
