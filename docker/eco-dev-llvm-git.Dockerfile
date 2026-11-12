# ============================================================
# eco-dev on LLVM/MLIR at an exact llvm-project commit: the libmax spike's
# layer for running eco on the LLVM that Modular MAX pins (see
# docker/llvm-debian-git.Dockerfile). Like eco-dev-genmc, it sits on top of
# the stable eco-dev image and leaves it alone; it swaps /opt/llvm-mlir for
# the one in eco-llvm-debian-git:<commit>.
#
# Build, after eco-dev and the commit's builder image:
#   C=8d4fc8f1d17e64e1826346a0230a87b50ec371e4
#   docker build -f docker/eco-dev-llvm-git.Dockerfile \
#     --build-arg LLVM_COMMIT=$C -t eco-dev-llvm-git:$C .
# then run eco-dev-llvm-git:<commit> exactly as eco-dev. The builder image is
# chosen by LLVM_COMMIT itself (no separate image argument to get wrong),
# and the build fails unless the copied tree records that same commit.
#
# The LLVM path is the same /opt/llvm-mlir, so a build/ tree configured in the
# LLVM 21 image must be deleted and reconfigured (cmake --preset build), never
# reused: it would mix objects compiled against LLVM 21 with the new libraries.
# ============================================================
ARG LLVM_COMMIT
ARG DEV_IMAGE=eco-dev
FROM eco-llvm-debian-git:${LLVM_COMMIT} AS llvm

FROM ${DEV_IMAGE}
ARG LLVM_COMMIT

LABEL org.opencontainers.image.description="eco-runtime development environment on llvm-project ${LLVM_COMMIT}"
LABEL org.eco.llvm.commit="${LLVM_COMMIT}"

# Remove the LLVM 21 tree first: COPY merges into an existing directory, and
# stale libraries left beside the new ones would link silently.
RUN rm -rf /opt/llvm-mlir
COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir
RUN test -n "${LLVM_COMMIT}" \
 && test "$(cat /opt/llvm-mlir/ECO_LLVM_COMMIT)" = "${LLVM_COMMIT}" \
 && echo "eco-dev on LLVM $(/opt/llvm-mlir/bin/llvm-config --version) at ${LLVM_COMMIT}"

ENV ECO_LLVM_COMMIT=${LLVM_COMMIT}
