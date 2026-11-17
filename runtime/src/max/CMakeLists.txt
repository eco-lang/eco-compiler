# eco's link to Modular MAX (plans/llvm-24-upgrade.md §5): the run-time loader, the
# check that guards MAX from modules it would crash on, and the smoke test. Added from
# runtime/src/codegen after find_package(MLIR), whose settings it inherits; built only
# when cmake/EcoMax.cmake turns MAX on.
include("${CMAKE_SOURCE_DIR}/cmake/EcoMax.cmake")
if(NOT ECO_MAX_ENABLED)
    return()
endif()

add_library(eco_max STATIC MaxLoader.cpp MaxVerify.cpp)
target_include_directories(eco_max PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(eco_max SYSTEM PUBLIC "${ECO_MAX_INCLUDE_DIR}")
target_link_libraries(eco_max PUBLIC MLIRParser MLIRBytecodeReader MLIRIR MLIRSupport ${CMAKE_DL_LIBS})
target_compile_features(eco_max PUBLIC cxx_std_20)

# The smoke test: loads the pinned MAX, runs a small graph, checks the guard (test/max/).
add_executable(max-smoke-test EXCLUDE_FROM_ALL "${CMAKE_SOURCE_DIR}/test/max/MaxSmokeTest.cpp")
target_link_libraries(max-smoke-test PRIVATE eco_max MLIRBytecodeWriter)
target_compile_definitions(max-smoke-test PRIVATE
    ECO_MAX_PACKAGE_ROOT="${ECO_MAX_PACKAGE_ROOT}"
    ECO_MAX_VERSION="${ECO_PIN_MAX_VERSION}"
    ECO_MAX_FIXTURES="${CMAKE_SOURCE_DIR}/test/max")

# Usage: cmake --build build --target run-max-smoke   (`full` runs it when MAX is on)
add_custom_target(run-max-smoke
    COMMAND max-smoke-test
    DEPENDS max-smoke-test
    COMMENT "MAX smoke test: load the pinned MAX, run a graph, check the guard"
    USES_TERMINAL)
