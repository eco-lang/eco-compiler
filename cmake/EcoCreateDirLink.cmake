# eco_create_dir_link(target_dir link_path)
#
# Create a directory alias at `link_path` pointing to `target_dir`. Used by
# the bootstrap shadow roots (compiler/build-xhr, compiler/build-kernel) and
# the test/ package shadows so an in-tree edit is visible inside the binary
# dir without copying.
#
# Implementation:
#   * POSIX: ordinary symbolic link via file(CREATE_LINK ... SYMBOLIC).
#   * Windows: NTFS junction via `mklink /J`. Junctions are directory-only
#     reparse points that require neither Developer Mode nor admin
#     elevation, unlike NTFS symbolic links — see plans/build-on-windows.md
#     item 5 (CMake hygiene sweep). Fallback to file(COPY) on the rare
#     filesystem that doesn't support junctions; that loses live-reflect of
#     source edits, which we surface as a configure-time WARNING.
function(eco_create_dir_link _target _link)
    if(NOT IS_DIRECTORY "${_target}")
        message(FATAL_ERROR
            "eco_create_dir_link: target is not an existing directory: ${_target}")
    endif()

    if(WIN32)
        # Wipe any pre-existing dir/junction at the link path; mklink refuses
        # if the destination exists.
        if(EXISTS "${_link}")
            file(REMOVE_RECURSE "${_link}")
        endif()
        file(TO_NATIVE_PATH "${_link}"   _link_nat)
        file(TO_NATIVE_PATH "${_target}" _target_nat)
        execute_process(
            COMMAND cmd /c mklink /J "${_link_nat}" "${_target_nat}"
            RESULT_VARIABLE _rc
            OUTPUT_QUIET
            ERROR_QUIET)
        if(NOT _rc EQUAL 0)
            message(WARNING
                "mklink /J '${_link}' -> '${_target}' failed (rc=${_rc}); "
                "falling back to file(COPY). Edits to the source tree will "
                "NOT be reflected until you reconfigure.")
            file(COPY "${_target}/" DESTINATION "${_link}")
        endif()
    else()
        file(REMOVE "${_link}")
        file(CREATE_LINK "${_target}" "${_link}" SYMBOLIC)
    endif()
endfunction()
