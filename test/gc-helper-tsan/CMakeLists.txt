# threaded-gc-03 Step 8 (plans/threaded-gc-03-helper-threads.md): the TSan
# harness for GCHelperPool + PageWork. A STANDALONE project, not part of the
# main build: the repo's clang 14 has no TSan runtime; build it with g++.
#
#   cmake -S test/gc-helper-tsan -B build-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
#   cmake --build build-tsan && timeout 900 build-tsan/gc-helper-tsan
#
# Pass: exit 0 and no "WARNING: ThreadSanitizer" in the output.
cmake_minimum_required(VERSION 3.20)
project(gc_helper_tsan CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(ECO_ALLOC ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src/allocator)
add_executable(gc-helper-tsan
    harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${ECO_ALLOC}/PageWork.cpp)
target_include_directories(gc-helper-tsan PRIVATE ${ECO_ALLOC})
target_compile_options(gc-helper-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG)
target_link_options(gc-helper-tsan PRIVATE -fsanitize=thread)
find_package(Threads REQUIRED)
target_link_libraries(gc-helper-tsan PRIVATE Threads::Threads)

# threaded-gc-05b Step 5: the parallel marker's std-only core (MarkWork.hpp:
# WorkStealingDeque + runMarkerLoop) and GCMarkGang, on a synthetic heap.
#   build-tsan/gc-mark-tsan   (pass: "mark_harness PASS", no TSan warning)
add_executable(gc-mark-tsan
    mark_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp)
target_include_directories(gc-mark-tsan PRIVATE ${ECO_ALLOC})
target_compile_options(gc-mark-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG)
target_link_options(gc-mark-tsan PRIVATE -fsanitize=thread)
target_link_libraries(gc-mark-tsan PRIVATE Threads::Threads)

# threaded-gc-06 Step 3: the parallel minor's std-only core (MinorWork.hpp:
# claim/publish header words, to-space LABs and fillers) driven by the real
# markwork::runMarkerLoop on GCMarkGang, over a synthetic heap.
#   build-tsan/gc-minor-tsan [heaps]   (pass: "minor_harness PASS", no TSan warning)
add_executable(gc-minor-tsan
    minor_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp)
target_include_directories(gc-minor-tsan PRIVATE ${ECO_ALLOC})
target_compile_options(gc-minor-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG)
target_link_options(gc-minor-tsan PRIVATE -fsanitize=thread)
target_link_libraries(gc-minor-tsan PRIVATE Threads::Threads)

# M3's TLA+ trace harness (plans/threaded-gc-tla-M3-minor-forwarding.md §9): the
# same minor_harness.cpp, NOT under TSan (trace builds and TSan builds are separate,
# parent plan §6.3), with the ECO_TLA_TRACE hooks compiled in and
# test/tla/trace/TlaTrace.cpp linked. test/tla/run_traces.py configures this
# project with -DECO_TLA_TRACE=ON and builds the target:
#   gc-minor-trace tiny <seed> <workers> <spine run> <pace us>   (writes $ECO_TLA_TRACE_OUT)
option(ECO_TLA_TRACE "Also build the TLA+ trace harnesses (no TSan)" OFF)
if(ECO_TLA_TRACE)
add_executable(gc-minor-trace
    minor_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-minor-trace PRIVATE ${ECO_ALLOC})
target_compile_definitions(gc-minor-trace PRIVATE ECO_TLA_TRACE=1)
target_compile_options(gc-minor-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-minor-trace PRIVATE Threads::Threads)
endif()

# threaded-gc-07 Steps 3 / 10: the tenure job's std-only core (TenureWork.hpp:
# shadow claim / publish, the resumable exact engine) on the real
# GCBackgroundGang, over a synthetic heap.
#   build-tsan/gc-tenure-tsan [storm jobs]   (pass: "tenure_harness PASS", no TSan warning)
add_executable(gc-tenure-tsan
    tenure_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp)
target_include_directories(gc-tenure-tsan PRIVATE ${ECO_ALLOC})
target_compile_options(gc-tenure-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG)
target_link_options(gc-tenure-tsan PRIVATE -fsanitize=thread)
target_link_libraries(gc-tenure-tsan PRIVATE Threads::Threads)

# M5's TLA+ trace harness (plans/threaded-gc-tla-M5-tenuring.md §9): the same
# tenure_harness.cpp, NOT under TSan, with TenureWork.hpp's ECO_TLA_TRACE hooks
# compiled in and test/tla/trace/TlaTrace.cpp linked (option ECO_TLA_TRACE above):
#   gc-tenure-trace tiny <seed> <jobs> <nten> <nfresh> <nold> <nylos> <nf> <stop %> <pace us>
#   (writes $ECO_TLA_TRACE_OUT)
if(ECO_TLA_TRACE)
add_executable(gc-tenure-trace
    tenure_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-tenure-trace PRIVATE ${ECO_ALLOC})
target_compile_definitions(gc-tenure-trace PRIVATE ECO_TLA_TRACE=1)
target_compile_options(gc-tenure-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-tenure-trace PRIVATE Threads::Threads)
endif()

# M7's TLA+ trace harness (plans/threaded-gc-tla-M7-pagework.md §8): harness.cpp's
# H2/H3 PageWork scripts, NOT under TSan, with PageWork's ECO_TLA_TRACE hooks
# compiled in and test/tla/trace/TlaTrace.cpp linked (option ECO_TLA_TRACE above):
#   gc-helper-trace pagework <fake|real> <threads> <jitter us> <steps> <extents>
#                   <ahead extents> <seed> [<delay syncs>]   (writes $ECO_TLA_TRACE_OUT)
if(ECO_TLA_TRACE)
add_executable(gc-helper-trace
    harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${ECO_ALLOC}/PageWork.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-helper-trace PRIVATE ${ECO_ALLOC})
target_compile_definitions(gc-helper-trace PRIVATE ECO_TLA_TRACE=1)
target_compile_options(gc-helper-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-helper-trace PRIVATE Threads::Threads)
endif()

# M2's TLA+ trace harness (plans/threaded-gc-tla-M2-slice-control.md §8): mark_harness.cpp's
# small slices / episode scenarios, NOT under TSan, with MarkWork.hpp's ECO_TLA_TRACE hooks
# compiled in and test/tla/trace/TlaTrace.cpp linked (option ECO_TLA_TRACE above):
#   gc-mark-trace slices <n> <L> <F> <slices> <max budget> <seed> <pace us>
#   gc-mark-trace episode <B> <L> <F> <assists> <assist budget> <end 0|1|2> <seed> <pace us>
# (each writes $ECO_TLA_TRACE_OUT)
if(ECO_TLA_TRACE)
add_executable(gc-mark-trace
    mark_harness.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-mark-trace PRIVATE ${ECO_ALLOC})
target_compile_definitions(gc-mark-trace PRIVATE ECO_TLA_TRACE=1)
target_compile_options(gc-mark-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-mark-trace PRIVATE Threads::Threads)
endif()

# M6's TLA+ trace harness (plans/threaded-gc-tla-M6-lifecycle.md §8): pool_trace.cpp, the
# real GCHelperPool with its M6 ECO_TLA_TRACE hooks, a scripted poster under a stand-in for
# Allocator::thread_mutex_, and a fork by another thread or by the poster, NOT under TSan
# (option ECO_TLA_TRACE above):
#   gc-pool-trace <none|host|mut-parent|mut-child> <seed> <ops> <workers> <jobs> <jitter us>
# (writes $ECO_TLA_TRACE_OUT; test/tla/M6-lifecycle/TracePool.tla)
if(ECO_TLA_TRACE)
add_executable(gc-pool-trace
    pool_trace.cpp
    ${ECO_ALLOC}/GCHelperPool.cpp
    ${ECO_ALLOC}/GCFork.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../tla/trace/TlaTrace.cpp)
target_include_directories(gc-pool-trace PRIVATE ${ECO_ALLOC})
target_compile_definitions(gc-pool-trace PRIVATE ECO_TLA_TRACE=1)
target_compile_options(gc-pool-trace PRIVATE -O1 -g -UNDEBUG)
target_link_libraries(gc-pool-trace PRIVATE Threads::Threads)
endif()
