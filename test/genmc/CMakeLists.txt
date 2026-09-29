# Weak-memory companions W1-W5 of the GC's TLA+ models
# (plans/threaded-gc-tla-W-weak-memory.md §11; test/genmc/AUDIT.md).
#
#   cmake --build build --target genmc-check     every row of drivers.txt under GenMC
#                                                (RC11): the drivers must pass, every
#                                                mutant must be flagged with its named
#                                                race or assertion, and the CR-001 /
#                                                CR-002 patterns must race
#
# Not in `check` or `full`, and not in CI: it runs locally at each TLA+ model's
# close-out and before a GC phase flips to default-on (parent plan §6.1-6.2;
# budget 10 minutes). run_drivers.py does the work and keeps
# GenMC's logs in build/genmc-logs/. Tools: genmc (the opt-in dev layer
# docker/eco-dev-genmc.Dockerfile installs it in /opt/genmc with docker/install-genmc.sh) and the clang of GenMC's LLVM (19). With
# genmc missing the target FAILS with a clear message; it never skips silently.
# Configure with -DECO_GENMC=OFF to leave it undefined on hosts without GenMC.

option(ECO_GENMC "Define the weak-memory model-checking target genmc-check" ON)

if(ECO_GENMC)
    find_program(ECO_GENMC_PYTHON3 python3)
    find_program(GENMC genmc PATHS /opt/genmc/bin)
    set(_genmc_runner "${CMAKE_CURRENT_SOURCE_DIR}/run_drivers.py")
    if(ECO_GENMC_PYTHON3 AND GENMC)
        add_custom_target(genmc-check
            COMMAND "${ECO_GENMC_PYTHON3}" "${_genmc_runner}" "--genmc=${GENMC}"
                    "--log-dir=${CMAKE_BINARY_DIR}/genmc-logs"
            WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            COMMENT "Weak-memory drivers W1-W5 under GenMC (test/genmc/drivers.txt)"
            USES_TERMINAL
            VERBATIM)
    else()
        add_custom_target(genmc-check
            COMMAND "${CMAKE_COMMAND}" -E echo
                    "genmc-check: genmc or python3 not found (GENMC=${GENMC}). Use the eco-dev-genmc image (docker/eco-dev-genmc.Dockerfile installs GenMC with docker/install-genmc.sh), or configure with -DECO_GENMC=OFF."
            COMMAND "${CMAKE_COMMAND}" -E false
            VERBATIM)
    endif()
endif()
