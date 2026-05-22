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

message(STATUS "Found Node.js: ${NODE_EXECUTABLE}")
message(STATUS "Found pnpm:    ${PNPM_EXECUTABLE}")

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
set(ECO_COMPILER_MLIR "${BUILD_KERNEL_DIR}/bin/eco-compiler.mlir")

add_custom_command(
    OUTPUT ${ECO_COMPILER_MLIR}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${BUILD_KERNEL_DIR}/eco-stuff
    COMMAND find ${BUILD_KERNEL_DIR}/eco-stuff -name *.ecot -delete
    COMMAND ${NODE_EXECUTABLE} --stack-size=65536 bin/eco-boot-2-runner.js make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-compiler.mlir
        ${ELM_ENTRY}
    DEPENDS ${ECO_BOOT_2_OUTPUT} ${ECO_BOOT_2_RUNNER_OUTPUT}
        ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 5: eco-boot-2.js → eco-compiler.mlir"
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
set(ECO_COMPILER_BOOT_MLIR "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot.mlir")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_MLIR}
    COMMAND ${ECO_COMPILER_ELF} make
        --optimize
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-compiler-boot.mlir
        ${ELM_ENTRY}
    DEPENDS ${ECO_COMPILER_ELF} ${ELM_SOURCES} ${KERNEL_SOURCES}
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Stage 7a: eco-compiler → eco-compiler-boot.mlir"
)

# -- Stage 7b: eco-compiler-boot.mlir → eco-compiler-boot (native ELF)
set(ECO_COMPILER_BOOT_ELF "${BUILD_KERNEL_DIR}/bin/eco-compiler-boot")

add_custom_command(
    OUTPUT ${ECO_COMPILER_BOOT_ELF}
    COMMAND $<TARGET_FILE:eco-boot-native>
        ${ECO_COMPILER_BOOT_MLIR}
        -o ${ECO_COMPILER_BOOT_ELF}
    DEPENDS ${ECO_COMPILER_BOOT_MLIR} eco-boot-native
    COMMENT "Stage 7b: eco-compiler-boot.mlir → eco-compiler-boot (native ELF)"
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
    DEPENDS ${ECO_COMPILER_MLIR} eco-boot-native
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

# Use the system default linker (GNU ld) for `eco`. The preset configures
# -fuse-ld=lld for the rest of the build, but lld rejects the
# R_X86_64_64 relocations the Elm-compiled object carries in its
# .llvm_stackmaps section (GC safepoint addresses tied to local function
# symbols) — see eco-boot.cpp's clang++ link invocation, which produces a
# working PIE eco-compiler binary by using the system ld. We mirror that
# here so the produced `eco` binary has the same PIE layout the GC
# stackmap parser in eco_entry.cpp expects.
target_link_options(eco PRIVATE -fuse-ld=bfd)

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
    pthread m stdc++ curl ssl crypto zip
    eco::llvm_libunwind
)

set(ECO_STAGE9_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco")
add_custom_target(eco-bootstrap DEPENDS eco)

# -- Stage 9c: native ELF fixed-point check (eco self-compiles to eco-2).
#
# Have `eco` compile its own front-end source to a second copy and bytewise
# compare. This is the strongest available fixed-point check — the whole
# binary (front-end + lowering pipeline + linker) is pinned as
# self-consistent.
#
# Known issue inherited from Stage 8: the upstream native fixed-point
# already has byte-equality problems we haven't fixed. Stage 9 surfaces the
# same issues; the fix belongs at the Stage 8 layer, not papered over here.
set(ECO_STAGE9_2_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-2")
set(ECO_STAGE9_VERIFY_STAMP
    "${CMAKE_CURRENT_BINARY_DIR}/eco-stage9-verify.stamp")

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

add_custom_command(
    OUTPUT ${ECO_STAGE9_VERIFY_STAMP}
    COMMAND ${CMAKE_COMMAND} -E compare_files
        ${ECO_STAGE9_OUTPUT} ${ECO_STAGE9_2_OUTPUT}
    COMMAND ${CMAKE_COMMAND} -E touch ${ECO_STAGE9_VERIFY_STAMP}
    DEPENDS ${ECO_STAGE9_OUTPUT} ${ECO_STAGE9_2_OUTPUT}
    COMMENT "Stage 9c: native ELF fixed-point check (eco == eco-2)"
)

add_custom_target(eco-verify DEPENDS ${ECO_STAGE9_VERIFY_STAMP})

# Aggregate: run the full bootstrap chain with all three fixed-point checks
# (Stage 4b JS, Stage 8c native intermediate, Stage 9c unified-eco).
add_custom_target(bootstrap
    DEPENDS ${ECO_BOOT_VERIFY_STAMP}
        ${BOOTSTRAP_STAMP}
        ${ECO_STAGE9_VERIFY_STAMP}
)

# Bootstrap outputs (${BUILD_XHR_DIR}/bin/, ${BUILD_KERNEL_DIR}/bin/,
# elm-stuff/, eco-stuff/) now live entirely under ${CMAKE_BINARY_DIR}. The
# add_custom_command OUTPUTs are ninja-tracked so `ninja clean` removes the
# generated *.js / *.mlir / native executables. Runtime caches (eco-stuff,
# elm-stuff) persist between builds; use `rm -rf build/` for a full reset.
