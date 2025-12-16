# Guida Elm Compiler build configuration
# This builds the guida compiler (an Elm compiler written in Elm)

# Find Node.js
find_program(NODE_EXECUTABLE node REQUIRED)
find_program(NPM_EXECUTABLE npm REQUIRED)

message(STATUS "Found Node.js: ${NODE_EXECUTABLE}")
message(STATUS "Found npm: ${NPM_EXECUTABLE}")

# Paths
set(COMPILER_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(COMPILER_OUTPUT "${COMPILER_DIR}/bin/guida.js")
set(ELM_ENTRY "${COMPILER_DIR}/src/Terminal/Main.elm")
set(ELM_EXECUTABLE "${COMPILER_DIR}/node_modules/.bin/elm")

# Collect all Elm source files for dependency tracking
file(GLOB_RECURSE ELM_SOURCES
    "${COMPILER_DIR}/src/*.elm"
)

# Also track key config files
set(COMPILER_CONFIG_FILES
    "${COMPILER_DIR}/elm.json"
    "${COMPILER_DIR}/package.json"
    "${COMPILER_DIR}/package-lock.json"
    "${COMPILER_DIR}/scripts/build.sh"
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

# Build the compiler
add_custom_command(
    OUTPUT ${COMPILER_OUTPUT}
    COMMAND ${ELM_EXECUTABLE} make --optimize --output=${COMPILER_OUTPUT} ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} scripts/replacements.js ${COMPILER_OUTPUT}
    DEPENDS ${NPM_STAMP} ${ELM_SOURCES} ${COMPILER_CONFIG_FILES}
    WORKING_DIRECTORY ${COMPILER_DIR}
    COMMENT "Building guida compiler"
)

# Create target for the compiler
add_custom_target(guida ALL DEPENDS ${COMPILER_OUTPUT})

# Clean target support - mark generated files for cleaning
set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES
    ${COMPILER_OUTPUT}
    "${COMPILER_DIR}/elm-stuff"
)
