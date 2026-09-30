# ============================================================
# eco-dev plus GenMC: an OPT-IN layer for the weak-memory drivers of the GC's
# TLA+ models (test/genmc/, target genmc-check;
# plans/threaded-gc-tla-W-weak-memory.md §4.2). CI does not build or use it:
# the model checks run locally, at a model's close-out and before a GC phase
# flips to default-on (plans/threaded-gc-tla-verification.md §6.2).
#
# Build, after eco-dev and the GenMC builder image:
#   docker build -f docker/genmc.Dockerfile -t eco-genmc:0.19.0-llvm19 .
#   docker build -f docker/eco-dev-genmc.Dockerfile -t eco-dev-genmc .
# then run eco-dev-genmc exactly as eco-dev (same entrypoint, same /work).
#
# /opt/genmc comes from the GenMC image; `install-genmc.sh runtime` installs what
# genmc needs at run time (Debian bookworm's clang-19, pinned by version: genmc
# compiles its input to LLVM 19 IR), links /usr/local/bin/genmc, and runs the
# same smoke test as the GenMC image (message passing passes, its relaxed mutant
# is flagged, a C++20 std::atomic_ref program compiles and passes). The
# project's own LLVM 21 is not involved. Bump GENMC_IMAGE's tag in lockstep with
# the pins in docker/install-genmc.sh.
# ============================================================
ARG GENMC_IMAGE=eco-genmc:0.19.0-llvm19
ARG DEV_IMAGE=eco-dev
FROM ${GENMC_IMAGE} AS genmc

FROM ${DEV_IMAGE}
ARG DEBIAN_FRONTEND=noninteractive
COPY --from=genmc /opt/genmc /opt/genmc
COPY docker/install-genmc.sh /tmp/install-genmc.sh
RUN sh /tmp/install-genmc.sh runtime \
 && rm /tmp/install-genmc.sh \
 && rm -rf /var/lib/apt/lists/*
