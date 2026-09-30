# ============================================================
# Builder image for GenMC (the C11/RC11 stateless model checker that runs the
# weak-memory companions W1-W5: plans/threaded-gc-tla-W-weak-memory.md §4.2,
# test/genmc/). Built once, then consumed by the opt-in dev layer
# docker/eco-dev-genmc.Dockerfile (eco-dev + GenMC) via
#   ARG GENMC_IMAGE=eco-genmc:0.19.0-llvm19
#   FROM ${GENMC_IMAGE} AS genmc
#   COPY --from=genmc /opt/genmc /opt/genmc
# The standard eco-dev image and CI do not use it.
#
# Build with:
#   docker build -f docker/genmc.Dockerfile -t eco-genmc:0.19.0-llvm19 .
# Bump the tag whenever docker/install-genmc.sh changes a pin (GenMC commit,
# LLVM version, GCC version).
#
# Everything is in docker/install-genmc.sh, so a dev container can run the
# same install by hand (`sudo`-capable user: `docker/install-genmc.sh build`).
# It builds a temporary GCC 14 (GenMC is C++23; bookworm's libstdc++ is 12),
# builds GenMC against Debian bookworm's LLVM 19, and smoke-tests the result
# (a message-passing litmus test must pass and its relaxed mutant must fail).
# ============================================================
FROM debian:bookworm
ARG DEBIAN_FRONTEND=noninteractive
ARG GENMC_JOBS=4

COPY docker/install-genmc.sh /tmp/install-genmc.sh
RUN GENMC_JOBS=${GENMC_JOBS} sh /tmp/install-genmc.sh build \
 && rm /tmp/install-genmc.sh \
 && rm -rf /var/lib/apt/lists/*
