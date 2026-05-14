# Guida Elm Compiler build configuration
# This builds the guida compiler (an Elm compiler written in Elm)

# Find Node.js
find_program(NODE_EXECUTABLE node REQUIRED)
find_program(NPM_EXECUTABLE npm REQUIRED)

message(STATUS "Found Node.js: ${NODE_EXECUTABLE}")
message(STATUS "Found npm: ${NPM_EXECUTABLE}")

# Paths
set(COMPILER_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

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
set(ELM_EXECUTABLE "${COMPILER_DIR}/node_modules/.bin/elm")

# Collect all Elm source files for dependency tracking
file(GLOB_RECURSE ELM_SOURCES
    "${COMPILER_DIR}/src/*.elm"
    "${COMPILER_DIR}/src-xhr/*.elm"
)

# Also track key config files
set(COMPILER_CONFIG_FILES
    "${BUILD_XHR_DIR}/elm.json"
    "${COMPILER_DIR}/package.json"
    "${COMPILER_DIR}/package-lock.json"
    "${COMPILER_DIR}/scripts/replacements.js"
)

# Ensure npm dependencies are installed
# We use a stamp file to track this
set(NPM_STAMP "${CMAKE_CURRENT_BINARY_DIR}/npm_install.stamp")

add_custom_command(
    OUTPUT ${NPM_STAMP}
    COMMAND ${NPM_EXECUTABLE} ci --prefer-offline
    COMMAND ${CMAKE_COMMAND} -E touch ${NPM_STAMP}
    DEPENDS "${COMPILER_DIR}/package.json" "${COMPILER_DIR}/package-lock.json"
    WORKING_DIRECTORY ${COMPILER_DIR}
    COMMENT "Installing npm dependencies for guida compiler"
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
file(REMOVE ${BUILD_KERNEL_DIR}/src ${BUILD_KERNEL_DIR}/src-kernel)
file(CREATE_LINK ${COMPILER_DIR}/src                   ${BUILD_KERNEL_DIR}/src        SYMBOLIC)
file(CREATE_LINK ${CMAKE_SOURCE_DIR}/eco-kernel-cpp/src ${BUILD_KERNEL_DIR}/src-kernel SYMBOLIC)

set(ECO_BOOT_OUTPUT        "${BUILD_KERNEL_DIR}/bin/eco-boot.js")
set(ECO_BOOT_RUNNER_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot-runner.js")

# Collect kernel source files for dependency tracking
file(GLOB_RECURSE KERNEL_SOURCES
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/*.elm"
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/Kernel/*.js"
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

# Aggregate: run the full bootstrap chain with both fixed-point checks.
add_custom_target(bootstrap
    DEPENDS ${ECO_BOOT_VERIFY_STAMP} ${BOOTSTRAP_STAMP}
)

# Bootstrap outputs (${BUILD_XHR_DIR}/bin/, ${BUILD_KERNEL_DIR}/bin/,
# elm-stuff/, eco-stuff/) now live entirely under ${CMAKE_BINARY_DIR}. The
# add_custom_command OUTPUTs are ninja-tracked so `ninja clean` removes the
# generated *.js / *.mlir / native executables. Runtime caches (eco-stuff,
# elm-stuff) persist between builds; use `rm -rf build/` for a full reset.
