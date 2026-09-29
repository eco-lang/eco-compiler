# TLA+ models of the threaded GC's concurrent protocols
# (plans/threaded-gc-tla-verification.md §4, §6; test/tla/README.md).
#
#   cmake --build build --target tla-check        quick tier: SANY, PlusCal translation
#                                                 freshness, every quick configuration,
#                                                 every mutant (each must fail with its
#                                                 named invariant)
#   cmake --build build --target tla-check-deep   deep tier (minutes to hours)
#   cmake --build build --target tla-trace        trace validation (<= 15 min): builds the
#                                                 trace harnesses (-DECO_TLA_TRACE=ON, g++,
#                                                 no TSan) into build/tla-trace/, runs them,
#                                                 merges each log and checks it with TLC
#
# The registries are models.txt (run_models.py) and traces.txt (run_traces.py); the
# runners keep their logs in build/tla-logs/<tier>/ and build/tla-logs/trace/ (the
# traces themselves too). Tools: java on PATH and tla2tools.jar, found at run time
# through -DTLA2TOOLS_JAR=... or $TLA_TOOLS_DIR (the dev image sets
# TLA_TOOLS_DIR=/opt/tlaplus). With the tools missing the targets FAIL with a clear
# message; they never skip silently. Configure with -DECO_TLA=OFF to leave them
# undefined on hosts without Java.

find_program(ECO_TLA_PYTHON3 python3)
set(TLA2TOOLS_JAR "" CACHE FILEPATH
    "tla2tools.jar for tla-check (default: $TLA_TOOLS_DIR/tla2tools.jar at run time)")

set(_tla_runner "${CMAKE_CURRENT_SOURCE_DIR}/run_models.py")
set(_tla_jar_arg "")
if(TLA2TOOLS_JAR)
    set(_tla_jar_arg "--jar=${TLA2TOOLS_JAR}")
endif()

if(ECO_TLA_PYTHON3)
    foreach(_tier quick deep)
        if(_tier STREQUAL "quick")
            set(_tla_target tla-check)
        else()
            set(_tla_target tla-check-deep)
        endif()
        add_custom_target(${_tla_target}
            COMMAND "${ECO_TLA_PYTHON3}" "${_tla_runner}" --tier ${_tier} ${_tla_jar_arg}
                    "--log-dir=${CMAKE_BINARY_DIR}/tla-logs/${_tier}"
            WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            COMMENT "TLA+ models, ${_tier} tier (test/tla/models.txt)"
            USES_TERMINAL
            VERBATIM)
    endforeach()
    # Trace validation (plans/threaded-gc-tla-verification.md §6.3). The harnesses need
    # cmake, ninja and g++ as well; the runner fails with a message if one is missing.
    add_custom_target(tla-trace
        COMMAND "${ECO_TLA_PYTHON3}" "${CMAKE_CURRENT_SOURCE_DIR}/run_traces.py" ${_tla_jar_arg}
                "--build-dir=${CMAKE_BINARY_DIR}/tla-trace"
                "--log-dir=${CMAKE_BINARY_DIR}/tla-logs/trace"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "TLA+ trace validation (test/tla/traces.txt)"
        USES_TERMINAL
        VERBATIM)
else()
    foreach(_tla_target tla-check tla-check-deep tla-trace)
        add_custom_target(${_tla_target}
            COMMAND "${CMAKE_COMMAND}" -E echo
                    "${_tla_target}: python3 not found; it runs test/tla/run_models.py / run_traces.py"
            COMMAND "${CMAKE_COMMAND}" -E false
            VERBATIM)
    endforeach()
endif()
