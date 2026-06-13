# Cross-platform replacement for `find DIR -name PATTERN -delete`. Used by
# the bootstrap chain to wipe stale .ecot Elm-typed-artifact files between
# stage 5 runs. Invoked via `cmake -P` so it works on Windows where
# POSIX `find` is absent. Glob is non-recursive when ECO_RECURSIVE is unset.
#
# Inputs (script mode): ECO_DIR, ECO_PATTERN, optionally ECO_RECURSIVE.

if(NOT ECO_DIR)
    message(FATAL_ERROR "EcoDeletePattern.cmake: ECO_DIR not set")
endif()
if(NOT ECO_PATTERN)
    message(FATAL_ERROR "EcoDeletePattern.cmake: ECO_PATTERN not set")
endif()

if(ECO_RECURSIVE)
    file(GLOB_RECURSE _files "${ECO_DIR}/${ECO_PATTERN}")
else()
    file(GLOB _files "${ECO_DIR}/${ECO_PATTERN}")
endif()
foreach(_f IN LISTS _files)
    file(REMOVE "${_f}")
endforeach()
