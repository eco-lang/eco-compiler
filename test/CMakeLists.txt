include_directories(../runtime/src/allocator/)
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# ============================================================================
# Per-package build-tree shadows
#
# Each Elm test package has its own elm.json declaring dependencies and a
# src/ directory holding the test sources. We materialize a shadow of each
# package under ${CMAKE_BINARY_DIR}/test/<pkg>/ so that the compiler's
# `findRoot` (which walks up from cwd looking for elm.json) anchors its
# eco-stuff/ and elm-stuff/ caches inside the build tree instead of polluting
# the source tree. elm.json is copied verbatim (each package's
# source-directories is already ["src"]); src/ is a symlink back to source.
# ============================================================================
set(ELM_TEST_PACKAGES
    elm
    elm-bytes
    eco-kernel
    elm-core
    elm-http
    elm-json
    elm-parser
    elm-regex
    elm-time
    elm-url
    stress-elm
)
include(${CMAKE_SOURCE_DIR}/cmake/EcoCreateDirLink.cmake)
foreach(pkg IN LISTS ELM_TEST_PACKAGES)
    set(_shadow "${CMAKE_BINARY_DIR}/test/${pkg}")
    file(MAKE_DIRECTORY ${_shadow})
    file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/${pkg}/elm.json DESTINATION ${_shadow})
    eco_create_dir_link(${CMAKE_CURRENT_SOURCE_DIR}/${pkg}/src ${_shadow}/src)
    # `cmake --build build --target clean` wipes the per-package eco-stuff
    # and elm-stuff caches (compiler-managed, regenerated on next run). The
    # shadow's elm.json and src symlink are configure-time scaffold and must
    # survive clean.
    set_property(DIRECTORY APPEND PROPERTY
            ADDITIONAL_CLEAN_FILES
                "${_shadow}/eco-stuff"
                "${_shadow}/elm-stuff"
    )
endforeach()

# Parallel shadow tree for the AOT E2E runner (test/aot-e2e/<pkg>/) so its
# .mlir / ELF / run-capture outputs live alongside, but do not collide with,
# the JIT E2E suite's outputs under test/<pkg>/. Each AOT shadow holds the
# package's elm.json plus a src symlink to the canonical source tree.
foreach(pkg IN LISTS ELM_TEST_PACKAGES)
    set(_aot_shadow "${CMAKE_BINARY_DIR}/test/aot-e2e/${pkg}")
    file(MAKE_DIRECTORY ${_aot_shadow})
    file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/${pkg}/elm.json DESTINATION ${_aot_shadow})
    eco_create_dir_link(${CMAKE_CURRENT_SOURCE_DIR}/${pkg}/src ${_aot_shadow}/src)
    # Wipe the AOT shadow's per-package caches on clean. Only the inner
    # cache dirs — the elm.json and src symlink are configure-time scaffold
    # (see ADDITIONAL_CLEAN_FILES warning below for the whole-tree variant).
    set_property(DIRECTORY APPEND PROPERTY
            ADDITIONAL_CLEAN_FILES
                "${_aot_shadow}/eco-stuff"
                "${_aot_shadow}/elm-stuff"
    )
endforeach()

# Find MLIR for codegen tests (EcoRunner depends on it)
find_package(MLIR REQUIRED CONFIG)
list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include_directories(${LLVM_INCLUDE_DIRS})
include_directories(${MLIR_INCLUDE_DIRS})
# LLVM_DEFINITIONS may be a single space-joined string (see the note in
# runtime/src/codegen/CMakeLists.txt); split it so each -D is its own flag.
separate_arguments(_llvm_defs NATIVE_COMMAND "${LLVM_DEFINITIONS}")
add_definitions(${_llvm_defs})

# Include codegen headers (for EcoRunner)
include_directories(../runtime/src/codegen)
include_directories(${CMAKE_BINARY_DIR}/runtime/src/codegen/include)

# Note: Allocator sources (Allocator.cpp, NurserySpace.cpp, etc.) are NOT included here
# because they are already compiled into the EcoRunner library. This ensures there's
# only one Allocator singleton so GC stats accumulate correctly across all tests.
add_executable(test
        main.cpp
        allocator/HeapGenerators.cpp
        allocator/TestHelpers.cpp
        allocator/NurserySpaceTest.cpp
        allocator/OldGenSpaceTest.cpp
        allocator/OldGenCapacityTest.cpp
        allocator/OldGenLazySweepTest.cpp
        allocator/OldGenSweepOnDemandTest.cpp
        allocator/OldGenSweepBudgetTest.cpp
        allocator/OldGenSmallClassBudgetTest.cpp
        allocator/AllocatorTest.cpp
        allocator/AllocatorCommonTest.cpp
        allocator/ElmTest.cpp
        allocator/HeapHelpersTest.cpp
        allocator/Utf8Test.cpp
        allocator/Utf8StringTest.cpp
        allocator/StringOpsTest.cpp
        allocator/ListOpsTest.cpp
        allocator/ChunkedListTest.cpp
        allocator/BytesOpsTest.cpp
        allocator/RuntimeExportsTest.cpp
        allocator/GenericApplyBoxingTest.cpp
        allocator/EcoApplyClosureTypedTest.cpp
        allocator/GCPressureTest.cpp
        allocator/EnsureHeadroomTest.cpp
        allocator/NurseryContiguityTest.cpp
        allocator/SliceRepresentationTest.cpp
        allocator/AddressSpaceReservationTest.cpp
        allocator/HPointerLayoutTest.cpp
        kernel/KernelExportsTest.cpp
)

target_compile_features(test PRIVATE cxx_std_20)
target_compile_options(test PRIVATE $<IF:$<PLATFORM_ID:Windows>,/EHsc,-fexceptions>)
# Windows: provide our minimal getopt_long shim before <getopt.h> resolves —
# the MSVC CRT has no getopt and main.cpp's command-line parsing relies on
# it. See test/win32/getopt.h. Also bake the weak-symbol /alternatename TU
# directly into the binary so Eco_Kernel_Order_register_gc_roots resolves
# without ElmKernel_Utils being linked (the JIT test binary deliberately
# omits ElmKernel — see eco_order_weak_stub_win32.cpp for the full story).
if(WIN32)
    target_include_directories(test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/win32)
    target_sources(test PRIVATE
        ${CMAKE_SOURCE_DIR}/runtime/src/codegen/eco_order_weak_stub_win32.cpp)
endif()
# BUILD_DIR locates the per-package shadow directories (test/<pkg>/elm.json +
# src symlink) materialized at configure time above. ElmE2ETestBase::findTestDir
# uses this to anchor the compiler's cwd, so eco-stuff/ and elm-stuff/ land
# under ${CMAKE_BINARY_DIR}/test/<pkg>/ rather than in the source tree.
#
# REPO_ROOT locates the in-tree eco/elm kernel packages (eco-kernel-cpp/,
# elm-kernel-cpp/) so EcoKernelTest / StressElmTest can pass them via
# --local-package eco/kernel=... — replaces an older hardcoded /work path
# (the Docker image's source root) that fails outside the container.
target_compile_definitions(test PRIVATE
    BUILD_DIR="${CMAKE_BINARY_DIR}"
    REPO_ROOT="${CMAKE_SOURCE_DIR}"
)
# Use --whole-archive for EcoRunner so that Scheduler/PlatformRuntime symbols
# are available when ElmKernel transitive dependencies are processed by the linker.
#
# Also whole-archive EcoKernel_MVar + EcoKernel_Runtime so the JIT's
# DynamicLibrarySearchGenerator can dlsym the `Eco_Kernel_MVar_*` kernel
# symbols (test/eco-kernel E2E suite drives the MVar kernel directly).
if(APPLE)
    # ld64 has no --whole-archive; -force_load takes one archive path per
    # flag. The plain target names afterwards keep the CMake dependency
    # edges (build ordering + transitive link interface).
    target_link_libraries(test rapidcheck
        -Wl,-force_load,$<TARGET_FILE:EcoRunner>
        -Wl,-force_load,$<TARGET_FILE:EcoKernel_MVar>
        -Wl,-force_load,$<TARGET_FILE:EcoKernel_Runtime>
        -Wl,-force_load,$<TARGET_FILE:EcoKernel_Http>
        EcoRunner
        EcoKernel_MVar
        EcoKernel_Runtime
        EcoKernel_Http
    )
elseif(WIN32)
    # /WHOLEARCHIVE: needs the .lib filename — bare target names get
    # passed to lld-link verbatim and fail. Use the TARGET_FILE generator
    # expression so the full path (including the .lib extension) lands
    # on the link line; same trick as the APPLE -force_load branch above.
    target_link_libraries(test rapidcheck
        EcoRunner
        EcoKernel_MVar
        EcoKernel_Runtime
        EcoKernel_Http
    )
    target_link_options(test PRIVATE
        /WHOLEARCHIVE:$<TARGET_FILE:EcoRunner>
        /WHOLEARCHIVE:$<TARGET_FILE:EcoKernel_MVar>
        /WHOLEARCHIVE:$<TARGET_FILE:EcoKernel_Runtime>
        /WHOLEARCHIVE:$<TARGET_FILE:EcoKernel_Http>
    )
else()
    target_link_libraries(test rapidcheck
        -Wl,--whole-archive
            EcoRunner
            EcoKernel_MVar
            EcoKernel_Runtime
            EcoKernel_Http
        -Wl,--no-whole-archive
    )
endif()
# Export symbols so the JIT can find them via dlsym.
set_target_properties(test PROPERTIES ENABLE_EXPORTS ON)

# Stress test runner — a separate binary so these can be built/run independently
# of the main E2E suite. Reuses ElmE2ETestBase/TestSuite/IsolatedTestRunner.
# On Windows the stress-elm/main.cpp hits the same Elm-E2E fork code paths the
# main suite stubs out; deferred until a CreateProcessW port lands.
if(NOT WIN32)
add_executable(stress-test
        stress-elm/main.cpp
)
target_compile_features(stress-test PRIVATE cxx_std_20)
target_compile_options(stress-test PRIVATE -fexceptions)
target_compile_definitions(stress-test PRIVATE
    BUILD_DIR="${CMAKE_BINARY_DIR}"
    REPO_ROOT="${CMAKE_SOURCE_DIR}"
)
# Mirror the kernel wiring on stress-test so stress-elm MVar cases work.
if(APPLE)
    target_link_libraries(stress-test
        -Wl,-force_load,$<TARGET_FILE:EcoRunner>
        -Wl,-force_load,$<TARGET_FILE:EcoKernel_MVar>
        -Wl,-force_load,$<TARGET_FILE:EcoKernel_Runtime>
        EcoRunner
        EcoKernel_MVar
        EcoKernel_Runtime
    )
else()
    target_link_libraries(stress-test
        -Wl,--whole-archive
            EcoRunner
            EcoKernel_MVar
            EcoKernel_Runtime
        -Wl,--no-whole-archive
    )
endif()
set_target_properties(stress-test PROPERTIES ENABLE_EXPORTS ON)
endif() # NOT WIN32 (stress-test)

# mlir-equivalence — compares Stage 2 (eco-boot.js) vs Stage 6 (eco-compiler
# native ELF) MLIR output across all Elm E2E test sources. Opt-in: requires
# the bootstrap chain through Stage 6 to be built first. `run-mlir-equivalence`
# DEPENDS on the relevant bootstrap outputs so a clean+run sequence rebuilds
# them automatically; the binary itself still preflights at startup and aborts
# with a diagnostic if anything is missing.
#
# Usage:
#     cmake --build build --target mlir-equivalence     # builds the binary
#     cmake --build build --target run-mlir-equivalence # builds + runs the suite
#     TEST_FILTER=Record cmake --build build --target run-mlir-equivalence
#
# mlir-equivalence and aot-e2e are gated off on Windows: both use the same
# fork-based test infrastructure as ElmE2ETestBase and the run-* targets
# wrap their invocation in `sh -c`. Porting them lands with the
# CreateProcessW pass that brings stress-elm back too.
if(NOT WIN32)
add_executable(mlir-equivalence
        mlir_equivalence_main.cpp
)
target_compile_features(mlir-equivalence PRIVATE cxx_std_20)
target_compile_options(mlir-equivalence PRIVATE -fexceptions)
target_compile_definitions(mlir-equivalence PRIVATE
        REPO_ROOT="${CMAKE_SOURCE_DIR}"
        BUILD_DIR="${CMAKE_BINARY_DIR}"
)

# `cmake --build build --target clean` should drop the per-run output tree
# (binary .mlir files and per-test --builddir scratch) alongside the regular
# object files. The directory is created on demand by the runner.
set_property(DIRECTORY APPEND PROPERTY
        ADDITIONAL_CLEAN_FILES "${CMAKE_BINARY_DIR}/test/mlir-equivalence-out"
)

# The three bootstrap outputs the runner needs at runtime. Listed as file
# dependencies (not target names) because `compiler/` is added after `test/`
# in the top-level CMakeLists, so the eco-boot / eco-compiler target names
# aren't yet visible here — file-level dependencies are resolved later, once
# both add_subdirectory calls have been processed.
set(MLIR_EQUIV_BOOTSTRAP_DEPS
        "${CMAKE_BINARY_DIR}/compiler/build-kernel/bin/eco-boot.js"
        "${CMAKE_BINARY_DIR}/compiler/build-kernel/bin/eco-boot-runner.js"
        "${CMAKE_BINARY_DIR}/compiler/build-kernel/bin/eco-compiler"
)

add_custom_target(run-mlir-equivalence
        COMMAND sh -c "$<TARGET_FILE:mlir-equivalence> $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
        DEPENDS mlir-equivalence ${MLIR_EQUIV_BOOTSTRAP_DEPS}
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        USES_TERMINAL
        COMMENT "Running Stage 2 vs Stage 6 MLIR equivalence tests"
)

# aot-e2e — Phase 5 of the pipeline-convergence plan. Compiles each Elm E2E
# test via Stage 3's eco-boot-2.js, lowers to native ELF via eco-boot-native,
# runs the binary, and verifies stdout against `-- CHECK:` directives.
#
# Outputs land in ${CMAKE_BINARY_DIR}/test/aot-e2e/ so they do not collide
# with the JIT E2E suite's outputs in ${CMAKE_BINARY_DIR}/test/<pkg>/.
#
# Usage:
#     cmake --build build --target aot-e2e         # build the runner only
#     cmake --build build --target run-aot-e2e    # build + run the suite
#     TEST_FILTER=Add cmake --build build --target run-aot-e2e
add_executable(aot-e2e-runner
        aot_e2e_main.cpp
)
target_compile_features(aot-e2e-runner PRIVATE cxx_std_20)
target_compile_options(aot-e2e-runner PRIVATE -fexceptions)
target_compile_definitions(aot-e2e-runner PRIVATE
        REPO_ROOT="${CMAKE_SOURCE_DIR}"
        BUILD_DIR="${CMAKE_BINARY_DIR}"
)
# TestHttpServer.hpp (included for the in-process elm-http + eco-kernel test
# server, mirroring ElmHttpTest/EcoKernelTest in the JIT runner) needs libssl
# + libcrypto for the throwaway self-signed TLS cert + SSL_accept loop.
find_package(OpenSSL REQUIRED)
target_link_libraries(aot-e2e-runner PRIVATE OpenSSL::SSL OpenSSL::Crypto)
# The JIT `test` binary includes the same TestHttpServer.hpp (via
# EcoKernelTest.hpp). It links EcoKernel_Http, but that archive's OpenSSL
# dependency is PRIVATE so its include path does not propagate — fine on Linux
# where openssl headers sit in the default search path, but brew's openssl@3 is
# keg-only on macOS. Link the imported targets so OpenSSL's INTERFACE include
# dir reaches test/main.cpp on both platforms. On Windows there is no
# OpenSSL — TestHttpServer.hpp is stubbed out behind `#if !defined(_WIN32)`
# (see ElmHttpTest.hpp and EcoKernelTest.hpp) so the test binary does not
# pull in any libcrypto symbols.
if(NOT WIN32)
    target_link_libraries(test OpenSSL::SSL OpenSSL::Crypto)
endif()

# NB: do NOT add ${CMAKE_BINARY_DIR}/test/aot-e2e (the whole tree) to
# ADDITIONAL_CLEAN_FILES. That tree's per-package elm.json + src/ symlinks
# are materialised at CMake configure time (via file(COPY)/file(CREATE_LINK)
# above), so ninja clean would wipe the scaffold and leave the shadow
# without an elm.json — the next Elm compile then reports "NO elm.json FILE"
# and every AOT test fails. The per-package eco-stuff/ and elm-stuff/ cache
# dirs ARE registered for clean (see the AOT shadow foreach above) — only
# the configure-time scaffold is held back. Use `rm -rf build/test/aot-e2e/`
# for a manual full wipe.

# Bootstrap inputs the AOT runner needs at runtime. eco-boot-2.js is produced
# by Stages 1+2+3 of guides/bootstrap.md; eco-boot-native is produced by the
# runtime CMake build. Listed as file dependencies because `compiler/` is
# added after `test/` in the top-level CMakeLists, so target names aren't
# visible here yet — file-level dependencies are resolved after both
# add_subdirectory calls have been processed.
set(AOT_E2E_BOOTSTRAP_DEPS
        "${CMAKE_BINARY_DIR}/compiler/build-kernel/bin/eco-boot-2.js"
        "${CMAKE_BINARY_DIR}/compiler/build-kernel/bin/eco-boot-2-runner.js"
        "${CMAKE_BINARY_DIR}/runtime/src/codegen/eco-boot-native"
)

add_custom_target(run-aot-e2e
        COMMAND sh -c "$<TARGET_FILE:aot-e2e-runner> $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
        DEPENDS aot-e2e-runner ${AOT_E2E_BOOTSTRAP_DEPS}
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        USES_TERMINAL
        COMMENT "Running AOT E2E tests via eco-boot-2.js + eco-boot-native"
)
endif() # NOT WIN32 (mlir-equivalence + aot-e2e-runner)
