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
    ${ECO_ALLOC}/PageWork.cpp)
target_include_directories(gc-helper-tsan PRIVATE ${ECO_ALLOC})
target_compile_options(gc-helper-tsan PRIVATE -fsanitize=thread -O1 -g -UNDEBUG)
target_link_options(gc-helper-tsan PRIVATE -fsanitize=thread)
find_package(Threads REQUIRED)
target_link_libraries(gc-helper-tsan PRIVATE Threads::Threads)
