# LLVMLibunwind.cmake
#
# Locates the libunwind shipped by LLVM (built via LLVM_ENABLE_RUNTIMES=libunwind)
# and exposes it as the imported INTERFACE target `eco::llvm_libunwind`. Linking
# against that target pulls in:
#   - the LLVM libunwind include directory (for <libunwind.h>)
#   - the LLVM libunwind shared library (via full path)
#   - an -Wl,-rpath entry so the loader finds the library without
#     LD_LIBRARY_PATH munging
#
# We deliberately do NOT fall back to the system (nongnu) libunwind: mixing the
# two implementations is how you end up debugging phantom unwinder crashes that
# only reproduce in one environment.
#
# Override search with either -DLLVM_INSTALL_PREFIX=<dir> or the env var of the
# same name; otherwise CMAKE_PREFIX_PATH (and anything MLIRConfig has already
# populated) is consulted.

if(TARGET eco::llvm_libunwind)
    return()
endif()

set(_llvm_libunwind_prefixes "")
if(DEFINED LLVM_INSTALL_PREFIX AND LLVM_INSTALL_PREFIX)
    list(APPEND _llvm_libunwind_prefixes "${LLVM_INSTALL_PREFIX}")
endif()
if(DEFINED ENV{LLVM_INSTALL_PREFIX} AND NOT "$ENV{LLVM_INSTALL_PREFIX}" STREQUAL "")
    list(APPEND _llvm_libunwind_prefixes "$ENV{LLVM_INSTALL_PREFIX}")
endif()
if(DEFINED LLVM_LIBRARY_DIR AND LLVM_LIBRARY_DIR)
    get_filename_component(_llvm_libunwind_from_libdir "${LLVM_LIBRARY_DIR}" DIRECTORY)
    list(APPEND _llvm_libunwind_prefixes "${_llvm_libunwind_from_libdir}")
endif()
foreach(_p IN LISTS CMAKE_PREFIX_PATH)
    list(APPEND _llvm_libunwind_prefixes "${_p}")
endforeach()
# CMake does not automatically promote the CMAKE_PREFIX_PATH env var to the
# CMake variable of the same name; find_package consults both, but a manual
# list iteration only sees the CMake variable. Read the env var explicitly.
if(DEFINED ENV{CMAKE_PREFIX_PATH} AND NOT "$ENV{CMAKE_PREFIX_PATH}" STREQUAL "")
    string(REPLACE ":" ";" _llvm_libunwind_env_paths "$ENV{CMAKE_PREFIX_PATH}")
    foreach(_p IN LISTS _llvm_libunwind_env_paths)
        list(APPEND _llvm_libunwind_prefixes "${_p}")
    endforeach()
endif()
list(REMOVE_ITEM _llvm_libunwind_prefixes "")
list(REMOVE_DUPLICATES _llvm_libunwind_prefixes)

# LLVM's runtimes install layout puts libraries in <prefix>/lib/<triple>/, where
# <triple> is LLVM_DEFAULT_TARGET_TRIPLE from the LLVM build — typically
# x86_64-unknown-linux-gnu, which does NOT match Debian's multiarch triple
# (x86_64-linux-gnu). We try the common candidates explicitly.
set(_llvm_libunwind_triples
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "${CMAKE_CXX_COMPILER_TARGET}"
    "${CMAKE_LIBRARY_ARCHITECTURE}"
)
list(REMOVE_DUPLICATES _llvm_libunwind_triples)

set(_llvm_libunwind_lib_dirs "")
foreach(_prefix IN LISTS _llvm_libunwind_prefixes)
    foreach(_triple IN LISTS _llvm_libunwind_triples)
        if(_triple)
            list(APPEND _llvm_libunwind_lib_dirs "${_prefix}/lib/${_triple}")
        endif()
    endforeach()
    list(APPEND _llvm_libunwind_lib_dirs "${_prefix}/lib")
endforeach()

find_library(LLVM_LIBUNWIND_LIBRARY
    NAMES unwind
    HINTS ${_llvm_libunwind_lib_dirs}
    NO_DEFAULT_PATH
    DOC "LLVM libunwind shared library (liunwind.so from LLVM_ENABLE_RUNTIMES)"
)

set(_llvm_libunwind_inc_dirs "")
foreach(_prefix IN LISTS _llvm_libunwind_prefixes)
    list(APPEND _llvm_libunwind_inc_dirs "${_prefix}/include")
endforeach()

find_path(LLVM_LIBUNWIND_INCLUDE_DIR
    NAMES libunwind.h
    HINTS ${_llvm_libunwind_inc_dirs}
    NO_DEFAULT_PATH
    DOC "Directory containing the LLVM libunwind.h"
)

if(NOT LLVM_LIBUNWIND_LIBRARY OR NOT LLVM_LIBUNWIND_INCLUDE_DIR)
    message(FATAL_ERROR
        "LLVM libunwind not found.\n"
        "  searched prefixes: ${_llvm_libunwind_prefixes}\n"
        "  searched lib dirs: ${_llvm_libunwind_lib_dirs}\n"
        "  searched include dirs: ${_llvm_libunwind_inc_dirs}\n"
        "Ensure LLVM was built with -DLLVM_ENABLE_RUNTIMES=libunwind and "
        "installed, then pass -DLLVM_INSTALL_PREFIX=<dir> or set CMAKE_PREFIX_PATH "
        "(e.g. /opt/llvm-mlir).")
endif()

# Distinguishing marker: LLVM's libunwind ships <__libunwind_config.h> alongside
# its libunwind.h; nongnu libunwind does not.
if(NOT EXISTS "${LLVM_LIBUNWIND_INCLUDE_DIR}/__libunwind_config.h")
    message(FATAL_ERROR
        "Found libunwind.h at ${LLVM_LIBUNWIND_INCLUDE_DIR}/libunwind.h but it "
        "does not appear to be the LLVM version (missing __libunwind_config.h). "
        "Refusing to mix libunwind implementations — point LLVM_INSTALL_PREFIX at "
        "an LLVM build that includes libunwind in LLVM_ENABLE_RUNTIMES.")
endif()

get_filename_component(LLVM_LIBUNWIND_LIBRARY_DIR "${LLVM_LIBUNWIND_LIBRARY}" DIRECTORY)

add_library(eco::llvm_libunwind INTERFACE IMPORTED GLOBAL)
set_target_properties(eco::llvm_libunwind PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${LLVM_LIBUNWIND_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES "${LLVM_LIBUNWIND_LIBRARY}"
    INTERFACE_LINK_OPTIONS "LINKER:-rpath,${LLVM_LIBUNWIND_LIBRARY_DIR}"
)

message(STATUS "LLVM libunwind:")
message(STATUS "  header:  ${LLVM_LIBUNWIND_INCLUDE_DIR}/libunwind.h")
message(STATUS "  library: ${LLVM_LIBUNWIND_LIBRARY}")
