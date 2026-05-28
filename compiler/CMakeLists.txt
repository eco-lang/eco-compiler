# Guida Elm Compiler build configuration
# This builds the guida compiler (an Elm compiler written in Elm)

# Linux x86_64 is the only platform with pinned toolchain binaries today.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux" OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    message(FATAL_ERROR
        "compiler/cmake/toolchain.cmake currently pins Linux x86_64 binaries only. "
        "System=${CMAKE_SYSTEM_NAME} Processor=${CMAKE_SYSTEM_PROCESSOR}.")
endif()

# Find Node.js and the package manager. The Elm toolchain itself (elm,
# elm-format, elm-test-rs) is fetched by cmake/toolchain.cmake — see below.
find_program(NODE_EXECUTABLE node REQUIRED)
find_program(PNPM_EXECUTABLE pnpm REQUIRED)
find_program(PYTHON3_EXECUTABLE python3 REQUIRED)
# GNU /usr/bin/time wraps Stages 5 and 7a so the front-end MLIR-emit timings
# (wall, CPU, RSS, page faults, ctx switches) can be summarized in a table.
find_program(GNU_TIME_EXECUTABLE NAMES time PATHS /usr/bin NO_DEFAULT_PATH REQUIRED)

message(STATUS "Found Node.js: ${NODE_EXECUTABLE}")
message(STATUS "Found pnpm:    ${PNPM_EXECUTABLE}")
message(STATUS "Found python3: ${PYTHON3_EXECUTABLE}")
message(STATUS "Found GNU time: ${GNU_TIME_EXECUTABLE}")

# Paths
set(COMPILER_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

include(${COMPILER_DIR}/cmake/toolchain.cmake)

# Build-tree shadow root for the Stage 1 XHR Elm application. We materialize
# elm.json + src/src-xhr/tests symlinks here at configure time so stock Elm
# and the bootstrap chain emit bin/, elm-stuff/, eco-stuff/ inside the CMake
# binary directory rather than into the source tree.
set(BUILD_XHR_DIR "${CMAKE_BINARY_DIR}/compiler/build-xhr")
file(MAKE_DIRECTORY ${BUILD_XHR_DIR})
file(COPY ${COMPILER_DIR}/cmake/bootstrap/build-xhr/elm.json
    DESTINATION ${BUILD_XHR_DIR})
file(COPY ${COMPILER_DIR}/elm-application.json
    DESTINATION ${BUILD_XHR_DIR})
file(REMOVE ${BUILD_XHR_DIR}/src ${BUILD_XHR_DIR}/src-xhr ${BUILD_XHR_DIR}/tests)
file(CREATE_LINK ${COMPILER_DIR}/src     ${BUILD_XHR_DIR}/src     SYMBOLIC)
file(CREATE_LINK ${COMPILER_DIR}/src-xhr ${BUILD_XHR_DIR}/src-xhr SYMBOLIC)
file(CREATE_LINK ${COMPILER_DIR}/tests   ${BUILD_XHR_DIR}/tests   SYMBOLIC)

set(COMPILER_OUTPUT "${BUILD_XHR_DIR}/bin/guida.js")
set(ELM_ENTRY "${COMPILER_DIR}/src/Terminal/Main.elm")
# ELM_EXECUTABLE is provided by cmake/toolchain.cmake above.

# Collect all Elm source files for dependency tracking
file(GLOB_RECURSE ELM_SOURCES
    "${COMPILER_DIR}/src/*.elm"
    "${COMPILER_DIR}/src-xhr/*.elm"
)

# Also track key config files
set(COMPILER_CONFIG_FILES
    "${BUILD_XHR_DIR}/elm.json"
    "${COMPILER_DIR}/package.json"
    "${COMPILER_DIR}/pnpm-lock.yaml"
    "${COMPILER_DIR}/scripts/replacements.js"
)

# Install Node runtime libraries via pnpm. The Elm toolchain itself is no
# longer in package.json; cmake/toolchain.cmake fetches those binaries with
# pinned SHAs. `--frozen-lockfile` + `ignore-scripts=true` (in .npmrc) keep
# this install hermetic.
set(NPM_STAMP "${CMAKE_CURRENT_BINARY_DIR}/pnpm_install.stamp")

add_custom_command(
    OUTPUT ${NPM_STAMP}
    COMMAND ${PNPM_EXECUTABLE} install --frozen-lockfile --prefer-offline
    COMMAND ${CMAKE_COMMAND} -E touch ${NPM_STAMP}
    DEPENDS "${COMPILER_DIR}/package.json" "${COMPILER_DIR}/pnpm-lock.yaml"
    WORKING_DIRECTORY ${COMPILER_DIR}
    COMMENT "Installing Node runtime libs via pnpm"
)

# Step 1: Build the compiler with stock Elm (XHR IO)
add_custom_command(
    OUTPUT ${COMPILER_OUTPUT}
    COMMAND ${ELM_EXECUTABLE} make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${COMPILER_OUTPUT}
    DEPENDS ${NPM_STAMP} ${ELM_SOURCES} ${COMPILER_CONFIG_FILES}
    WORKING_DIRECTORY ${BUILD_XHR_DIR}
    COMMENT "Building guida compiler (step 1: XHR)"
)

# Create target for the compiler
add_custom_target(guida ALL DEPENDS ${COMPILER_OUTPUT})

# Convenience wrapper: run the elm-test-rs suite against the build-xhr shadow
# root. Replaces `cd compiler && npx elm-test-rs --project build-xhr`.
#
# elm-test-rs invokes the elm compiler as a subprocess and discovers it via
# PATH, so we prepend the CMake-fetched toolchain dir.
add_custom_target(elm-tests
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TOOLCHAIN_BIN}:$ENV{PATH}"
        ${ELM_TEST_RS_EXECUTABLE} --project ${BUILD_XHR_DIR} --fuzz 1
    DEPENDS guida
    WORKING_DIRECTORY ${COMPILER_DIR}
    COMMENT "Running elm-test-rs against build-xhr shadow root"
    USES_TERMINAL
    VERBATIM
)

# Step 2: Self-compile with eco kernel JS

# Build-tree shadow for stages 2–8 (kernel JS + native bootstrap chain).
set(BUILD_KERNEL_DIR "${CMAKE_BINARY_DIR}/compiler/build-kernel")
file(MAKE_DIRECTORY ${BUILD_KERNEL_DIR})
file(COPY
    ${COMPILER_DIR}/cmake/bootstrap/build-kernel/elm.json
    ${COMPILER_DIR}/cmake/bootstrap/build-kernel/heap-config.json
    ${COMPILER_DIR}/cmake/bootstrap/build-kernel/inject-bytecode-monitor.js
    ${COMPILER_DIR}/cmake/bootstrap/build-kernel/inject-mem.js
    ${COMPILER_DIR}/cmake/bootstrap/build-kernel/run-eol2.js
    DESTINATION ${BUILD_KERNEL_DIR})
file(REMOVE ${BUILD_KERNEL_DIR}/src ${BUILD_KERNEL_DIR}/src-kernel ${BUILD_KERNEL_DIR}/node_modules)
file(CREATE_LINK ${COMPILER_DIR}/src                   ${BUILD_KERNEL_DIR}/src        SYMBOLIC)
file(CREATE_LINK ${CMAKE_SOURCE_DIR}/eco-kernel-cpp/src ${BUILD_KERNEL_DIR}/src-kernel SYMBOLIC)
# Eco.Kernel.Http.js does `require('adm-zip')` when downloading package
# archives. Without this symlink, node walks up from eco-boot.js's location
# (.../build-kernel/bin/) and never reaches ${COMPILER_DIR}/node_modules,
# so the require throws → compiler reports "unable to unzip the data" for
# every package download. The link is created at configure time; it'll
# dangle until `pnpm install` populates ${COMPILER_DIR}/node_modules, then
# becomes live with no further action needed.
file(CREATE_LINK ${COMPILER_DIR}/node_modules          ${BUILD_KERNEL_DIR}/node_modules SYMBOLIC)

set(ECO_BOOT_OUTPUT        "${BUILD_KERNEL_DIR}/bin/eco-boot.js")
set(ECO_BOOT_RUNNER_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot-runner.js")

# Collect kernel source files for dependency tracking
file(GLOB_RECURSE KERNEL_SOURCES
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/*.elm"
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/Kernel/*.js"
)

# The Elm compiler caches compiled package artifacts at <local-package>/artifacts.dat
# and <local-package>/typed-artifacts.dat (see Builder.Stuff.typedPackageArtifacts).
# When --local-package eco/kernel=<eco-kernel-cpp> is used, that root is the
# checked-out source tree, so the caches land in-tree. They are gitignored, and
# we need `cmake --build build --target clean` to wipe them — otherwise edits
# to eco-kernel-cpp/src/Eco/Kernel/*.js are masked by the stale artifact cache
# and never reach the bundled compiler. .gitignore: eco-kernel-cpp/.gitignore
# already lists artifacts.dat / typed-artifacts.dat.
set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_CLEAN_FILES
    "${COMPILER_DIR}/../eco-kernel-cpp/artifacts.dat"
    "${COMPILER_DIR}/../eco-kernel-cpp/typed-artifacts.dat"
)

# Pre-baked runner contents — written at configure time into the CMake build
# dir, then copied into place by each stage. This is the trivial Node
# entrypoint that loads eco-boot{,-2}.js and invokes Terminal.Main; it used to
# be written inline by scripts/build-self.sh / build-verify.sh. Going through
# file(WRITE) + cmake -E copy sidesteps the shell-quoting nightmare of
# embedding the literal source as a `sh -c "printf ..."` step.
set(ECO_BOOT_RUNNER_TEMPLATE   "${CMAKE_CURRENT_BINARY_DIR}/eco-boot-runner.template.js")
set(ECO_BOOT_2_RUNNER_TEMPLATE "${CMAKE_CURRENT_BINARY_DIR}/eco-boot-2-runner.template.js")
file(WRITE ${ECO_BOOT_RUNNER_TEMPLATE}
    "const { Elm } = require(\"./eco-boot.js\");\nElm.Terminal.Main.init();\n")
file(WRITE ${ECO_BOOT_2_RUNNER_TEMPLATE}
    "const { Elm } = require(\"./eco-boot-2.js\");\nElm.Terminal.Main.init();\n")

# `eco-boot-runner.js` is required by Stage 3 onwards. Make sure bin/ exists
# explicitly (clean wipes the whole tree) before copying the runner in.
add_custom_command(
    OUTPUT ${ECO_BOOT_OUTPUT} ${ECO_BOOT_RUNNER_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${BUILD_KERNEL_DIR}/bin
    # index.js loads guida.js via require(GUIDA_JS_PATH ?? default). Pass the
    # absolute build-tree path so non-default CMake build dirs (e.g. debug/)
    # resolve correctly.
    COMMAND ${CMAKE_COMMAND} -E env "GUIDA_JS_PATH=${COMPILER_OUTPUT}"
        ${NODE_EXECUTABLE} ${COMPILER_DIR}/bin/index.js make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=${ECO_BOOT_OUTPUT}
        ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${ECO_BOOT_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E copy ${ECO_BOOT_RUNNER_TEMPLATE} ${ECO_BOOT_RUNNER_OUTPUT}
    DEPENDS ${COMPILER_OUTPUT} ${ELM_SOURCES} ${KERNEL_SOURCES}
        ${ECO_BOOT_RUNNER_TEMPLATE} "${BUILD_KERNEL_DIR}/elm.json"
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Building eco-boot compiler (step 2: kernel)"
)

add_custom_target(eco-boot DEPENDS ${ECO_BOOT_OUTPUT} ${ECO_BOOT_RUNNER_OUTPUT})

# Step 3: eco-boot self-compilation verification
set(ECO_BOOT_2_OUTPUT        "${BUILD_KERNEL_DIR}/bin/eco-boot-2.js")
set(ECO_BOOT_2_RUNNER_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot-2-runner.js")

# Stage 3 produces eco-boot-2.js AND its matching runner; Stages 4 and 5 both
# invoke the runner.
add_custom_command(
    OUTPUT ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_2_RUNNER_OUTPUT}
    COMMAND ${NODE_EXECUTABLE} bin/eco-boot-runner.js make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-boot-2.js
        ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${ECO_BOOT_2_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E copy ${ECO_BOOT_2_RUNNER_TEMPLATE} ${ECO_BOOT_2_RUNNER_OUTPUT}
    DEPENDS ${ECO_BOOT_OUTPUT} ${ECO_BOOT_RUNNER_OUTPUT} ${ELM_SOURCES} ${KERNEL_SOURCES}
        ${ECO_BOOT_2_RUNNER_TEMPLATE}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Building eco-boot-2 (step 3: self-verify)"
)

add_custom_target(eco-boot-2 DEPENDS ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_2_RUNNER_OUTPUT})

# ============================================================================
# Stages 4–8: native bootstrap chain
#
# Opt-in: `cmake --build build --target bootstrap` runs the full chain with
# both fixed-point checks. Each stage's output depends on its predecessor +
# the same ${ELM_SOURCES} ${KERNEL_SOURCES} globs used for stages 2/3, so an
# edit anywhere in compiler/src or eco-kernel-cpp/src reruns the whole chain.
# ============================================================================

# -- Stage 4a: eco-boot-2.js self-compiles → eco-boot-3.js
set(ECO_BOOT_3_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot-3.js")

add_custom_command(
    OUTPUT ${ECO_BOOT_3_OUTPUT}
    COMMAND ${NODE_EXECUTABLE} bin/eco-boot-2-runner.js make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-boot-3.js
        ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${ECO_BOOT_3_OUTPUT}
    DEPENDS ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_2_RUNNER_OUTPUT}
        ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 4a: eco-boot-2.js → eco-boot-3.js"
)

add_custom_target(eco-boot-3 DEPENDS ${ECO_BOOT_3_OUTPUT})

# -- Stage 4b: JS fixed-point check (eco-boot-2.js == eco-boot-3.js)
set(ECO_BOOT_VERIFY_STAMP "${CMAKE_CURRENT_BINARY_DIR}/eco-boot-verify.stamp")

add_custom_command(
    OUTPUT ${ECO_BOOT_VERIFY_STAMP}
    COMMAND ${CMAKE_COMMAND} -E compare_files ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_3_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E touch ${ECO_BOOT_VERIFY_STAMP}
    DEPENDS ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_3_OUTPUT}
    COMMENT "Stage 4b: JS fixed-point check (eco-boot-2.js == eco-boot-3.js)"
)

add_custom_target(eco-boot-verify DEPENDS ${ECO_BOOT_VERIFY_STAMP})

# -- Stage 5: eco-boot-2.js → eco-compiler.mlir
# Stale .ecot caches from a prior MLIR build cause crashes during
# monomorphization (e.g. `Union not found: SCC`). Stages 2–4 don't write or
# invalidate .ecot files, so any pre-existing .ecot under build-kernel/eco-stuff
# must be wiped before running this stage.
#
# Front-end MLIR emit is wrapped in /usr/bin/time -v so wall/CPU/RSS stats land
# in STAGE5_TIME_LOG; print-mlir-timings.py summarizes them in a table at the
# end of `mlir-timing-report` / `bootstrap`.
set(ECO_COMPILER_MLIR "${BUILD_KERNEL_DIR}/bin/eco-compiler.mlir")
set(STAGE5_TIME_LOG   "${BUILD_KERNEL_DIR}/timing-stage5.txt")

add_custom_command(
    OUTPUT ${ECO_COMPILER_MLIR}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${BUILD_KERNEL_DIR}/eco-stuff
    COMMAND find ${BUILD_KERNEL_DIR}/eco-stuff -name *.ecot -delete
    COMMAND ${GNU_TIME_EXECUTABLE} -v -o ${STAGE5_TIME_LOG}
        ${NODE_EXECUTABLE} --stack-size=65536 bin/eco-boot-2-runner.js make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-compiler.mlir
        ${ELM_ENTRY}
    BYPRODUCTS ${STAGE5_TIME_LOG}
    # Ordering edge: Stage 5 must wait for Stage 4b's JS fixed-point diff so
    # the bootstrap chain runs in the order documented in guides/bootstrap.md.
    # Without this, Ninja is free to start Stage 5 the moment Stage 3's
    # eco-boot-2.js exists, racing past the Stage 4 verification.
    DEPENDS ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_2_RUNNER_OUTPUT}
        ${ECO_BOOT_VERIFY_STAMP}
        ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 5: eco-boot-2.js → eco-compiler.mlir (timed)"
)

add_custom_target(eco-compiler-mlir DEPENDS ${ECO_COMPILER_MLIR})

# -- Stage 6: eco-compiler.mlir → eco-compiler (native ELF)
# eco-boot-native is defined in runtime/src/codegen/CMakeLists.txt.
set(ECO_COMPILER_ELF "${BUILD_KERNEL_DIR}/bin/eco-compiler")

add_custom_command(
    OUTPUT ${ECO_COMPILER_ELF}
    COMMAND $<TARGET_FILE:eco-boot-native>
        ${ECO_COMPILER_MLIR}
        -o ${ECO_COMPILER_ELF}
    DEPENDS ${ECO_COMPILER_MLIR} eco-boot-native
    COMMENT "Stage 6: eco-compiler.mlir → eco-compiler (native ELF)"
)

add_custom_target(eco-compiler DEPENDS ${ECO_COMPILER_ELF})

# -- Stage 7a: eco-compiler self-compiles → eco-compiler-boot.mlir
# Front-end MLIR emit wrapped in /usr/bin/time -v, paralleling Stage 5.
set(ECO_COMPILER_BOOT_MLIR "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot.mlir")
set(STAGE7A_TIME_LOG       "${BUILD_KERNEL_DIR}/timing-stage7a.txt")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_MLIR}
    COMMAND ${GNU_TIME_EXECUTABLE} -v -o ${STAGE7A_TIME_LOG}
        ${ECO_COMPILER_ELF} make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-compiler-boot.mlir
        ${ELM_ENTRY}
    BYPRODUCTS ${STAGE7A_TIME_LOG}
    DEPENDS ${ECO_COMPILER_ELF} ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 7a: eco-compiler → eco-compiler-boot.mlir (timed)"
)

# -- Stage 7b: eco-compiler-boot.mlir → eco-compiler-boot (native ELF)
# eco-boot-native invocation wrapped in /usr/bin/time -v so the lowering+link
# stats line up next to the Stage 5 and 7a front-end stats in the report.
set(ECO_COMPILER_BOOT_ELF "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot")
set(STAGE7B_TIME_LOG      "${BUILD_KERNEL_DIR}/timing-stage7b.txt")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_ELF}
    COMMAND ${GNU_TIME_EXECUTABLE} -v -o ${STAGE7B_TIME_LOG}
        $<TARGET_FILE:eco-boot-native>
        ${ECO_COMPILER_BOOT_MLIR}
        -o ${ECO_COMPILER_BOOT_ELF}
    BYPRODUCTS ${STAGE7B_TIME_LOG}
    DEPENDS ${ECO_COMPILER_BOOT_MLIR} eco-boot-native
    COMMENT "Stage 7b: eco-compiler-boot.mlir → eco-compiler-boot (native ELF, timed)"
)

add_custom_target(eco-compiler-boot DEPENDS ${ECO_COMPILER_BOOT_ELF})

# -- Stage 8a: eco-compiler-boot self-compiles → eco-compiler-boot-2.mlir
set(ECO_COMPILER_BOOT_2_MLIR "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot-2.mlir")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_2_MLIR}
    COMMAND ${ECO_COMPILER_BOOT_ELF} make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-compiler-boot-2.mlir
        ${ELM_ENTRY}
    DEPENDS ${ECO_COMPILER_BOOT_ELF} ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 8a: eco-compiler-boot → eco-compiler-boot-2.mlir"
)

# -- Stage 8b: eco-compiler-boot-2.mlir → eco-compiler-boot-2 (native ELF)
set(ECO_COMPILER_BOOT_2_ELF "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot-2")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_2_ELF}
    COMMAND $<TARGET_FILE:eco-boot-native>
        ${ECO_COMPILER_BOOT_2_MLIR}
        -o ${ECO_COMPILER_BOOT_2_ELF}
    DEPENDS ${ECO_COMPILER_BOOT_2_MLIR} eco-boot-native
    COMMENT "Stage 8b: eco-compiler-boot-2.mlir → eco-compiler-boot-2 (native ELF)"
)

# -- Stage 8c: native fixed-point check (eco-compiler-boot == eco-compiler-boot-2)
set(BOOTSTRAP_STAMP "${CMAKE_CURRENT_BINARY_DIR}/bootstrap.stamp")

add_custom_command(
    OUTPUT ${BOOTSTRAP_STAMP}
    COMMAND ${CMAKE_COMMAND} -E compare_files ${ECO_COMPILER_BOOT_ELF} ${ECO_COMPILER_BOOT_2_ELF}
    COMMAND ${CMAKE_COMMAND} -E touch ${BOOTSTRAP_STAMP}
    DEPENDS ${ECO_COMPILER_BOOT_ELF} ${ECO_COMPILER_BOOT_2_ELF}
    COMMENT "Stage 8c: native fixed-point check (eco-compiler-boot == eco-compiler-boot-2)"
)

# ============================================================================
# Stage 9: unified `eco` single-file compiler
#
# Stage 9 fuses the front-end (Stage 6's eco-compiler) and the back-end
# (eco-boot-native's lowering+linking pipeline) into one ELF binary. From the
# user's perspective `eco` is a drop-in replacement for `elm make` that also
# accepts extension-less / unknown `--output=` names, which trigger the
# in-process MLIR -> ELF pipeline via the `Eco.NativeDriver.lowerAndLink`
# kernel intrinsic backed by EcoNativeDriverStatic.
#
# Phase 1: build eco-compiler.mlir → eco-stage9.o (eco-boot-native --emit=obj)
# → link with EcoEntryStatic + EcoRuntimeStatic + all kernels +
# EcoNativeDriverStatic (under --whole-archive so the strong
# eco_native_lower_and_link symbol is pulled in to satisfy the weak undef
# from EcoKernel_NativeDriver).
# ============================================================================

# -- Stage 9a: lower eco-compiler.mlir to a relocatable object for `eco`.
set(ECO_STAGE9_OBJ "${BUILD_KERNEL_DIR}/bin/eco-stage9.o")

add_custom_command(
    OUTPUT ${ECO_STAGE9_OBJ}
    COMMAND $<TARGET_FILE:eco-boot-native>
        ${ECO_COMPILER_MLIR}
        --emit=obj
        -o ${ECO_STAGE9_OBJ}
    # Ordering edge: gate Stage 9 on Stage 7's native ELF. Stage 9's inputs
    # (eco-compiler.mlir + eco-boot-native) are otherwise ready at the end of
    # Stage 5, which lets Ninja race Stage 9 ahead of Stages 6–8. Hanging
    # Stage 9 off the Stage 7 ELF forces the chain through Stages 6 and 7
    # first; Stages 8 and 9 are then free to run in parallel after Stage 7.
    DEPENDS ${ECO_COMPILER_MLIR} eco-boot-native ${ECO_COMPILER_BOOT_ELF}
    COMMENT "Stage 9a: eco-compiler.mlir → eco-stage9.o"
)

# Mark as external so add_executable accepts it as a precompiled source.
set_source_files_properties(${ECO_STAGE9_OBJ} PROPERTIES
    GENERATED TRUE
    EXTERNAL_OBJECT TRUE
)

# -- Stage 9b: link the unified `eco` ELF binary.
#
# Per-module ElmKernel / EcoKernel libs are listed explicitly because the
# umbrella INTERFACE targets don't reliably pull static archives. The link
# line is wrapped in --start-group / --end-group via raw `-Wl,*` strings
# (CMake 3.20 lacks LINK_GROUP). ElmKernel_Utils is whole-archived so its
# Order-singleton registrar (Eco_Kernel_Order_register_gc_roots) is always
# linked — same reason eco-boot.cpp's linkExecutable does it. The
# EcoNativeDriverStatic whole-archive is what makes the strong
# eco_native_lower_and_link symbol present, so the kernel intrinsic's weak
# undef resolves to a working implementation.
# EXCLUDE_FROM_ALL: `eco` transitively depends on eco-stage9.o → eco-compiler.mlir
# (Stage 5) → eco-boot-2.js (Stage 3) → eco-boot.js (Stage 2). Without
# EXCLUDE_FROM_ALL, every `cmake --build build` (and therefore the `full`
# Gate-A target) would run Stages 3, 5, and 9. We want default builds to
# stop at Stage 2 (Gate A's prerequisite); Stage 9 only builds on explicit
# request via `--target eco`, `--target eco-bootstrap`, or `--target bootstrap`.
add_executable(eco EXCLUDE_FROM_ALL ${ECO_STAGE9_OBJ})

set_target_properties(eco PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${BUILD_KERNEL_DIR}/bin"
)

# Linker for `eco` (ECO_LINK_WITH_BFD, top-level CMakeLists.txt). The preset
# configures -fuse-ld=lld for the rest of the build, but lld rejects the
# R_X86_64_64 relocations the Elm-compiled object carries in its
# .llvm_stackmaps section (GC safepoint addresses tied to local function
# symbols) when producing a PIE — see eco-boot.cpp's clang++ link invocation,
# which produces a working PIE eco-compiler binary by using the system ld. The
# glibc builds mirror that here so the produced `eco` binary has the same PIE
# layout the GC stackmap parser in eco_entry.cpp expects. The Stage B MUSL
# build is non-PIE static, where lld accepts those relocs, so the musl preset
# sets ECO_LINK_WITH_BFD=OFF and `eco` inherits the preset's -fuse-ld=lld.
if(ECO_LINK_WITH_BFD)
    target_link_options(eco PRIVATE -fuse-ld=bfd)
endif()

# Static-link extras. See plans/static-link-eco-binary.md.
if(ECO_STATIC AND ECO_STATIC_MUSL)
    # Stage B (MUSL): the `-static` link, the libc++ runtime stack, and the
    # compiler-rt builtins + LLVM libunwind all arrive via the preset's global
    # EXE_LINKER_FLAGS (-static -stdlib=libc++ -rtlib=compiler-rt
    # -unwindlib=libunwind -lc++abi). Because compiler-rt replaces libgcc, the
    # _Unwind_* collision that forces --allow-multiple-definition on the glibc
    # path never arises — nothing extra is needed on the target here.
elseif(ECO_STATIC)
    # Stage A (glibc): pull libstdc++ and libgcc into the binary so the only
    # shared deps left are glibc + the dynamic linker (Stage A, Step 5).
    # --allow-multiple-definition resolves the _Unwind_* collision between
    # clang's auto-added libgcc_eh.a (from -static-libgcc) and the explicit
    # LLVM libunwind.a (eco::llvm_libunwind) — libunwind.a is earlier in the
    # link line, so its definitions win and libgcc_eh.a's are dropped.
    target_link_options(eco PRIVATE
        -static-libstdc++ -static-libgcc
        -Wl,--allow-multiple-definition)
endif()

target_link_libraries(eco PRIVATE
    "-Wl,--start-group"
    EcoEntryStatic
    EcoRuntimeStatic
    "-Wl,--whole-archive"
    ElmKernel_Utils
    "-Wl,--no-whole-archive"
    ElmKernel_Basics ElmKernel_Bitwise ElmKernel_Char ElmKernel_String
    ElmKernel_List ElmKernel_JsArray ElmKernel_Debug ElmKernel_Scheduler
    ElmKernel_Platform ElmKernel_Process ElmKernel_VirtualDom ElmKernel_Json
    ElmKernel_Browser ElmKernel_Bytes ElmKernel_File ElmKernel_Http
    ElmKernel_Parser ElmKernel_Regex ElmKernel_Time ElmKernel_Url
    ElmKernel_EffectRegistry
    EcoKernel_File EcoKernel_Console EcoKernel_Env EcoKernel_Process
    EcoKernel_MVar EcoKernel_NativeDriver EcoKernel_Runtime EcoKernel_Http
    EcoKernel_Crash
    # EcoNativeDriverStatic inside the group so its strong
    # eco_native_lower_and_link definition overrides the weak stub in
    # EcoEntryStatic. No --whole-archive: the kernel module's strong
    # external reference is what pulls EcoNativeDriver.cpp out of the
    # archive, and nothing else in EcoNativeDriverStatic ships static
    # initializers that should run unconditionally.
    EcoNativeDriverStatic
    "-Wl,--end-group"
    pthread m
    eco::llvm_libunwind
)

# libstdc++ entry. With ECO_STATIC the driver's -static-libstdc++ inserts
# libstdc++.a at the right place; a bare `-lstdc++` here would resolve to
# the .so first and shadow the static one. Without ECO_STATIC, keep the
# explicit `-lstdc++` because the driver-added entry comes too late in the
# link order for some EcoEntryStatic / kernel symbol references.
if(NOT ECO_STATIC)
    target_link_libraries(eco PRIVATE stdc++)
endif()

# Under ECO_STATIC the curl/ssl/crypto/zip libraries reach the link line as
# transitive PRIVATE dependencies of EcoKernel_Http (pkg-config's
# Libs.private closure on Debian, or the FetchContent libzip target). The
# bare `-lcurl -lssl -lcrypto -lzip` flags below are appended only for the
# dynamic build; under ECO_STATIC they would re-resolve to the .so siblings
# and defeat the static link.
if(NOT ECO_STATIC)
    target_link_libraries(eco PRIVATE curl ssl crypto zip)
endif()

# Static-link probe (Stage A verification). Same kernel + runtime dep tree
# as `eco` but with a trivial main() instead of the MLIR-generated Stage-9
# object. Lets us exercise the static link path (ldd / readelf) without
# running the Elm bootstrap chain. EXCLUDE_FROM_ALL — default builds skip
# it; built explicitly via `--target eco-static-link-probe`.
if(ECO_STATIC)
    add_executable(eco-static-link-probe EXCLUDE_FROM_ALL
        ${CMAKE_CURRENT_BINARY_DIR}/static_link_probe.cpp
    )
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/static_link_probe.cpp
        "int main() { return 0; }\n")
    set_target_properties(eco-static-link-probe PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${BUILD_KERNEL_DIR}/bin"
    )
    # Mirror eco's linker/runtime selection (see the eco target above).
    if(ECO_LINK_WITH_BFD)
        target_link_options(eco-static-link-probe PRIVATE -fuse-ld=bfd)
    endif()
    if(NOT ECO_STATIC_MUSL)
        target_link_options(eco-static-link-probe PRIVATE
            -static-libstdc++ -static-libgcc
            -Wl,--allow-multiple-definition)
    endif()
    target_link_libraries(eco-static-link-probe PRIVATE
        "-Wl,--start-group"
        EcoEntryStatic EcoRuntimeStatic
        "-Wl,--whole-archive"
        ElmKernel_Utils
        "-Wl,--no-whole-archive"
        ElmKernel_Basics ElmKernel_Bitwise ElmKernel_Char ElmKernel_String
        ElmKernel_List ElmKernel_JsArray ElmKernel_Debug ElmKernel_Scheduler
        ElmKernel_Platform ElmKernel_Process ElmKernel_VirtualDom ElmKernel_Json
        ElmKernel_Browser ElmKernel_Bytes ElmKernel_File ElmKernel_Http
        ElmKernel_Parser ElmKernel_Regex ElmKernel_Time ElmKernel_Url
        ElmKernel_EffectRegistry
        EcoKernel_File EcoKernel_Console EcoKernel_Env EcoKernel_Process
        EcoKernel_MVar EcoKernel_NativeDriver EcoKernel_Runtime EcoKernel_Http
        EcoKernel_Crash
        EcoNativeDriverStatic
        "-Wl,--end-group"
        pthread m
        eco::llvm_libunwind
    )
endif()

set(ECO_STAGE9_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco")
add_custom_target(eco-bootstrap DEPENDS eco)

# -- Stage 9b: eco self-compiles to a second binary (eco-2).
#
# Have `eco` compile its own front-end source through its in-process
# NativeDriver to a second binary. This proves the unified `eco` can
# self-host: drive the front-end, lower the MLIR, and link an ELF.
#
# There is deliberately NO eco == eco-2 byte-equality check. Only `eco` itself
# embeds the LLVM/MLIR lowering back-end (the strong eco_native_lower_and_link
# from EcoNativeDriverStatic). Programs `eco` produces — including eco-2 — are
# ordinary AOT binaries: the kernel intrinsic resolves to the weak stub and no
# back-end is linked in. So eco (~226 MB, ~165k llvm::/mlir:: symbols) and
# eco-2 (~73 MB, none) differ by construction. A successful Stage 9b
# self-compile is the success criterion for the unified binary.
set(ECO_STAGE9_2_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-2")

add_custom_command(
    OUTPUT ${ECO_STAGE9_2_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E env "NODE_OPTIONS=--max-old-space-size=12000"
        ${ECO_STAGE9_OUTPUT} make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-2
        ${ELM_ENTRY}
    DEPENDS ${ECO_STAGE9_OUTPUT} ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 9b: eco → eco-2 (in-process MLIR -> ELF via NativeDriver)"
)

# `eco-verify` now just drives the Stage 9b self-compile (eco → eco-2); see the
# note above for why there is no eco == eco-2 equality check.
add_custom_target(eco-verify DEPENDS ${ECO_STAGE9_2_OUTPUT})

# ============================================================================
# MLIR-pipeline compile-timing report
#
# Stages 5, 7a, and 7b each leave a `/usr/bin/time -v` log behind. The script
# pairs each log with the stage's output file (the resulting .mlir text or
# native ELF) and prints a side-by-side comparison table. The arg shape is
#   <title> <label> <time-log> <output-file> [...]
# so adding/removing columns is just an arg-list edit on the caller side.
# ============================================================================
set(MLIR_TIMING_SCRIPT "${COMPILER_DIR}/cmake/print-mlir-timings.py")
set(MLIR_TIMING_ARGS
    "MLIR pipeline compile timings"
    "Stage 5 (JS → MLIR)"   ${STAGE5_TIME_LOG}  ${ECO_COMPILER_MLIR}
    "Stage 7a (ELF → MLIR)" ${STAGE7A_TIME_LOG} ${ECO_COMPILER_BOOT_MLIR}
    "Stage 7b (MLIR → ELF)" ${STAGE7B_TIME_LOG} ${ECO_COMPILER_BOOT_ELF}
)

# Standalone target — prints whatever timing data is currently on disk. Safe
# to invoke before any stage has run; missing data renders as '-'. Useful
# after partial builds (e.g. `--target eco-compiler-mlir`) to see Stage 5 in
# isolation.
add_custom_target(mlir-timing-report
    COMMAND ${PYTHON3_EXECUTABLE} ${MLIR_TIMING_SCRIPT} ${MLIR_TIMING_ARGS}
    COMMENT "MLIR pipeline compile-timing report"
    VERBATIM
)

# Aggregate: run the full bootstrap chain with the two fixed-point checks
# (Stage 4b JS, Stage 8c native intermediate) plus the Stage 9b unified-eco
# self-compile, then print the MLIR-pipeline timing table as the final step.
add_custom_target(bootstrap
    COMMAND ${PYTHON3_EXECUTABLE} ${MLIR_TIMING_SCRIPT} ${MLIR_TIMING_ARGS}
    DEPENDS ${ECO_BOOT_VERIFY_STAMP}
        ${BOOTSTRAP_STAMP}
        ${ECO_STAGE9_2_OUTPUT}
    VERBATIM
)

# Bootstrap outputs (${BUILD_XHR_DIR}/bin/, ${BUILD_KERNEL_DIR}/bin/,
# elm-stuff/, eco-stuff/) now live entirely under ${CMAKE_BINARY_DIR}. The
# add_custom_command OUTPUTs are ninja-tracked so `ninja clean` removes the
# generated *.js / *.mlir / native executables. Runtime caches (eco-stuff,
# elm-stuff) persist between builds; use `rm -rf build/` for a full reset.
