# GlibcRuntimeAudit.cmake — build-time audit of the Stage D glibc
# output-runtime tree. Run as `cmake -DTREE=<dir> -P` by the
# eco-glibc-runtime-tree target (top-level CMakeLists.txt).
#
# Two jobs, both required by plans/stage-d-hybrid-link-profiles.md (step 2):
#
#   1. PIC audit. Every archive staged into the tree is trial-linked with
#      `ld.lld -shared --whole-archive` — a non-PIC member fails with a
#      relocation error (the way Debian's system libz.a does), turning a
#      would-be user-visible .so/.node link failure into a build-time one.
#      Undefined symbols are fine (-shared allows them, exactly as the real
#      Stage D link does); --no-dependent-libraries mirrors the real link
#      line so libc++'s .deplibs hints don't false-positive.
#
#   2. Glibc floor. The Stage D link binds no libc, so produced .so/.node
#      carry unversioned UND refs and NO DT_VERNEED — nothing enforces a
#      glibc version at load time. Compute the honest floor here instead:
#      collect the undefined symbols of all staged archives, look each up
#      in the BUILD host's libc/libm export tables (default versions are
#      what unversioned references bind to), and record the maximum.
#      Outputs: <tree>/UND_SYMBOLS.txt and <tree>/GLIBC_FLOOR.
#
# Host tools: ld.lld (lld), nm, objdump, bash — all present in the
# eco-llvm-debian builder image.

if(NOT TREE OR NOT EXISTS "${TREE}")
    message(FATAL_ERROR "GlibcRuntimeAudit: TREE not set or missing: '${TREE}'")
endif()

find_program(AUDIT_LLD NAMES ld.lld lld REQUIRED)
find_program(AUDIT_NM NAMES llvm-nm nm REQUIRED)
find_program(AUDIT_OBJDUMP NAMES objdump llvm-objdump REQUIRED)
find_program(AUDIT_BASH NAMES bash REQUIRED)

file(GLOB_RECURSE _archives "${TREE}/*.a")
if(NOT _archives)
    message(FATAL_ERROR "GlibcRuntimeAudit: no archives found under ${TREE}")
endif()

# --- 1. PIC audit -----------------------------------------------------------
# Each trial mirrors the REAL Stage D link's conditions:
#   - --exclude-libs=ALL: the real link hides every archive except the two
#     whole-archived entry libs, making defined symbols non-preemptible.
#     Without this the trial false-fails on legal PC32 refs to own-archive
#     definitions (and embed/glue, the two un-hidden ones, pass either way).
#   - the tree's compiler-rt builtins ride along (lazy, not whole-archived):
#     clang emits direct R_X86_64_PC32 to __cpu_model (__builtin_cpu_supports
#     in ElmKernel_Regex's srell) expecting that link-local definition —
#     a lone-archive trial would false-fail on it.
#   - NO -z notext: stricter than the real link. The .llvm_stackmaps TEXTREL
#     lives in the user object, never in archives — an archive needing
#     textrels IS mispackaged.
set(_trial_out "${TREE}/.pic-audit-trial.so")
set(_builtins "${TREE}/libclang_rt.builtins-x86_64.a")
foreach(_a ${_archives})
    execute_process(
        COMMAND ${AUDIT_LLD} -shared --no-dependent-libraries
                --exclude-libs=ALL
                --whole-archive ${_a} --no-whole-archive
                ${_builtins}
                -o ${_trial_out}
        RESULT_VARIABLE _rc
        OUTPUT_VARIABLE _out
        ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR
            "GlibcRuntimeAudit: PIC trial link FAILED for ${_a} — a non-PIC "
            "(or otherwise -shared-unlinkable) archive must never reach the "
            "bundle's glibc/ tree.\n${_err}")
    endif()
endforeach()
file(REMOVE "${_trial_out}")
list(LENGTH _archives _n)
message(STATUS "GlibcRuntimeAudit: PIC audit passed for ${_n} archives")

# --- 2. UND symbol set + glibc floor ----------------------------------------
# Delegated to cmake/glibc_floor.sh (a real script file — embedding the
# pipeline in a CMake string mangles the awk/quote escaping). Symbols
# satisfied by neither libc nor libm (napi_*, host-app callbacks) simply
# don't match the export tables and are ignored for the floor.
execute_process(
    COMMAND ${AUDIT_BASH} ${CMAKE_CURRENT_LIST_DIR}/glibc_floor.sh
            ${TREE} ${AUDIT_NM} ${AUDIT_OBJDUMP}
    RESULT_VARIABLE _rc
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE _err)
if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "GlibcRuntimeAudit: floor computation failed:\n${_out}\n${_err}")
endif()
message(STATUS "${_out}")
