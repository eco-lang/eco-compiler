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

# macOS: the system unwinder IS LLVM libunwind (libSystem re-exports it; the
# implementation originated at Apple) and <libunwind.h> ships in the CLT SDK.
# There is nothing to locate or link — expose an empty interface target so
# consumers' target_link_libraries(eco::llvm_libunwind) lines work unchanged.
if(APPLE)
    add_library(eco_llvm_libunwind_system INTERFACE)
    add_library(eco::llvm_libunwind ALIAS eco_llvm_libunwind_system)
    message(STATUS "LLVMLibunwind: Darwin — using the system libunwind (it is LLVM libunwind)")
    return()
endif()

# Windows: libunwind is not used. StackUnwind.cpp falls back to
# RtlVirtualUnwind, the JIT registers frames via RtlAddFunctionTable, and
# C++ exception handling routes through MSVC native SEH. See
# plans/build-on-windows.md (libunwind line in Dependency mapping). Expose
# an empty interface target so target_link_libraries(eco::llvm_libunwind)
# calls remain platform-neutral.
if(WIN32)
    add_library(eco_llvm_libunwind_system INTERFACE)
    add_library(eco::llvm_libunwind ALIAS eco_llvm_libunwind_system)
    message(STATUS "LLVMLibunwind: Windows — libunwind not used (RtlVirtualUnwind + RtlAddFunctionTable)")
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

# Under ECO_STATIC we want the static archive (libunwind.a) and no rpath;
# otherwise we want the shared library (libunwind.so) loaded via an embedded
# -Wl,-rpath. Naming `libunwind.a` explicitly bypasses
# CMAKE_FIND_LIBRARY_SUFFIXES, which would otherwise prefer `.so` even when
# only `.a` is wanted.
if(ECO_STATIC)
    find_library(LLVM_LIBUNWIND_LIBRARY
        NAMES libunwind.a
        HINTS ${_llvm_libunwind_lib_dirs}
        NO_DEFAULT_PATH
        DOC "LLVM libunwind static archive (libunwind.a from LLVM_ENABLE_RUNTIMES)"
    )
else()
    find_library(LLVM_LIBUNWIND_LIBRARY
        NAMES unwind
        HINTS ${_llvm_libunwind_lib_dirs}
        NO_DEFAULT_PATH
        DOC "LLVM libunwind shared library (libunwind.so from LLVM_ENABLE_RUNTIMES)"
    )
endif()

set(_llvm_libunwind_inc_dirs "")
foreach(_prefix IN LISTS _llvm_libunwind_prefixes)
    list(APPEND _llvm_libunwind_inc_dirs "${_prefix}/include")
endforeach()
# Debian/Ubuntu apt packaging (libunwind-XX-dev, the LLVM unwinder) nests
# the headers at /usr/include/libunwind/{libunwind.h,__libunwind_config.h}
# while the archive sits under /usr/lib/llvm-XX/lib. Appended AFTER the
# explicit prefixes so a source-built LLVM still wins; the nongnu
# libunwind-dev package puts a bare /usr/include/libunwind.h instead, which
# this dir doesn't match and the __libunwind_config.h marker check below
# would reject anyway. Used by Stage D's glibc-runtime stage
# (-DLLVM_INSTALL_PREFIX=/usr/lib/llvm-14 finds only the archive).
list(APPEND _llvm_libunwind_inc_dirs "/usr/include/libunwind")

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
)
if(NOT ECO_STATIC)
    # Static archive needs no rpath; the .so does (no LD_LIBRARY_PATH munging).
    set_target_properties(eco::llvm_libunwind PROPERTIES
        INTERFACE_LINK_OPTIONS "LINKER:-rpath,${LLVM_LIBUNWIND_LIBRARY_DIR}"
    )
endif()

message(STATUS "LLVM libunwind:")
message(STATUS "  header:  ${LLVM_LIBUNWIND_INCLUDE_DIR}/libunwind.h")
message(STATUS "  library: ${LLVM_LIBUNWIND_LIBRARY}")
