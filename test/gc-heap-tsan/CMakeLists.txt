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
cmake_minimum_required(VERSION 3.20)
project(gc_heap_tsan CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(ECO_ALLOC ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src/allocator)
file(GLOB ECO_ALLOC_SRC ${ECO_ALLOC}/*.cpp)
list(FILTER ECO_ALLOC_SRC EXCLUDE REGEX "(PlatformVirtualMemory_win32|StackUnwind)\\.cpp$")
add_executable(gc-heap-tsan heap_driver.cpp stub_unwind.cpp ${ECO_ALLOC_SRC})
target_include_directories(gc-heap-tsan PRIVATE ${ECO_ALLOC}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../elm-kernel-cpp/vendor)
target_compile_definitions(gc-heap-tsan PRIVATE ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1)
target_compile_options(gc-heap-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG -Wno-tsan)
target_link_options(gc-heap-tsan PRIVATE -fsanitize=thread)
find_package(Threads REQUIRED)
target_link_libraries(gc-heap-tsan PRIVATE Threads::Threads)
