# Guida Elm Compiler build configuration
# This builds the guida compiler (an Elm compiler written in Elm)

# Find Node.js
find_program(NODE_EXECUTABLE node REQUIRED)
find_program(NPM_EXECUTABLE npm REQUIRED)

message(STATUS "Found Node.js: ${NODE_EXECUTABLE}")
message(STATUS "Found npm: ${NPM_EXECUTABLE}")

# Paths
set(COMPILER_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(BUILD_XHR_DIR "${COMPILER_DIR}/build-xhr")
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
set(BUILD_KERNEL_DIR "${COMPILER_DIR}/build-kernel")
set(ECO_BOOT_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot.js")

# Collect kernel source files for dependency tracking
file(GLOB_RECURSE KERNEL_SOURCES
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/*.elm"
    "${COMPILER_DIR}/../eco-kernel-cpp/src/Eco/Kernel/*.js"
)

add_custom_command(
    OUTPUT ${ECO_BOOT_OUTPUT}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/bin/index.js make
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=${ECO_BOOT_OUTPUT}
        ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${ECO_BOOT_OUTPUT}
    DEPENDS ${COMPILER_OUTPUT} ${ELM_SOURCES} ${KERNEL_SOURCES} "${BUILD_KERNEL_DIR}/elm.json"
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Building eco-boot compiler (step 2: kernel)"
)

add_custom_target(eco-boot DEPENDS ${ECO_BOOT_OUTPUT})

# Step 3: eco-boot self-compilation verification
set(ECO_BOOT_2_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot-2.js")

add_custom_command(
    OUTPUT ${ECO_BOOT_2_OUTPUT}
    COMMAND ${NODE_EXECUTABLE} bin/eco-boot-runner.js make
        --kernel-package eco/compiler
        --local-package eco/kernel=${COMPILER_DIR}/../eco-kernel-cpp
        --output=bin/eco-boot-2.js
        ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${ECO_BOOT_2_OUTPUT}
    DEPENDS ${ECO_BOOT_OUTPUT} ${ELM_SOURCES} ${KERNEL_SOURCES}
        "${BUILD_KERNEL_DIR}/bin/eco-boot-runner.js"
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Building eco-boot-2 (step 3: self-verify)"
)

add_custom_target(eco-boot-2 DEPENDS ${ECO_BOOT_2_OUTPUT})

# Clean target support - mark generated files for cleaning
set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES
    ${COMPILER_OUTPUT}
    ${ECO_BOOT_OUTPUT}
    ${ECO_BOOT_2_OUTPUT}
    "${BUILD_XHR_DIR}/elm-stuff"
    "${BUILD_KERNEL_DIR}/elm-stuff"
)
