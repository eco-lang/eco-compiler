# Ties a build tree to the llvm-project commit deps/versions.env pins. Call eco_check_llvm_pin()
# right after find_package(MLIR):
#
#   - the LLVM found must record that commit (<prefix>/ECO_LLVM_COMMIT, written by every eco LLVM
#     build: docker/llvm-*.Dockerfile, experiments/{mac,win}-llvm-build); otherwise configure fails,
#     naming both commits and how to get the right LLVM;
#   - a build tree remembers the commit it was configured against (ECO_CONFIGURED_LLVM_COMMIT), and
#     refuses to be reconfigured against another: objects compiled against one LLVM must never be
#     linked with another's libraries.
#
# -DECO_LLVM_PIN_CHECK=OFF skips both, for an LLVM eco did not build (it then only warns).
include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/EcoVersions.cmake")

option(ECO_LLVM_PIN_CHECK "Require the LLVM found to be the commit deps/versions.env pins" ON)

function(eco_check_llvm_pin)
    set(_file "${LLVM_INSTALL_PREFIX}/ECO_LLVM_COMMIT")
    set(_found "")
    if(EXISTS "${_file}")
        file(READ "${_file}" _found)
        string(STRIP "${_found}" _found)
    endif()
    set(_want "${ECO_PIN_LLVM_COMMIT}")
    set(_how "Get the pinned LLVM: in the dev container, local-dev/build-images.sh (then start a new container with local-dev/dev.sh); on macOS or Windows, the llvm-build workflow's artifact (scripts/deps.sh artifact macos|windows) or experiments/{mac,win}-llvm-build. Pass -DECO_LLVM_PIN_CHECK=OFF to build against another LLVM anyway.")

    if(NOT _found STREQUAL _want)
        if(_found STREQUAL "")
            set(_what "records no commit (no ${_file})")
        else()
            set(_what "is llvm-project ${_found}")
        endif()
        if(ECO_LLVM_PIN_CHECK)
            message(FATAL_ERROR "The LLVM at ${LLVM_INSTALL_PREFIX} (${LLVM_PACKAGE_VERSION}) ${_what}, but deps/versions.env pins ${_want}.\n${_how}")
        else()
            message(WARNING "ECO_LLVM_PIN_CHECK=OFF: building against ${LLVM_INSTALL_PREFIX}, which ${_what}, not the pinned ${_want}.")
        endif()
    else()
        message(STATUS "LLVM ${LLVM_PACKAGE_VERSION} at llvm-project ${_found} (the pin)")
    endif()

    if(ECO_LLVM_PIN_CHECK AND DEFINED CACHE{ECO_CONFIGURED_LLVM_COMMIT}
       AND NOT "$CACHE{ECO_CONFIGURED_LLVM_COMMIT}" STREQUAL "${_found}")
        message(FATAL_ERROR "This build tree (${CMAKE_BINARY_DIR}) was configured against llvm-project $CACHE{ECO_CONFIGURED_LLVM_COMMIT}, and is now being configured against ${_found}. Its objects were compiled against the old LLVM and must not be linked with the new one: delete the build tree and configure afresh.")
    endif()
    set(ECO_CONFIGURED_LLVM_COMMIT "${_found}" CACHE INTERNAL "The llvm-project commit this build tree was configured against")
endfunction()
