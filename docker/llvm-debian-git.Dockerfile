# ============================================================
# Builder image for LLVM + MLIR at an exact llvm-project commit (Debian)
# ============================================================
# The libmax spike's variant of docker/llvm-debian.Dockerfile: the same
# configuration, built from one llvm/llvm-project commit instead of a release
# tag, so eco can run on the LLVM that Modular MAX pins and exchange MLIR with
# it directly (spikes/max/README.md). MAX pins LLVM by commit in
# bazel/public-patches/llvm_source.bzl of github.com/modular/modular; the
# max/v26.7.0 tag (the MAX in the spike) pins
#   8d4fc8f1d17e64e1826346a0230a87b50ec371e4   (2026-10-09, "24.0.0git")
# Modular's own patches on top of that commit (mostly AMDGPU/NVPTX codegen)
# are not applied.
#
# The stable images are untouched: this is a separate image name,
# eco-llvm-debian-git, tagged with the full 40-hex commit, never a release
# number. LLVM_COMMIT has no default, so the build fails rather than guess,
# and /opt/llvm-mlir/ECO_LLVM_COMMIT records the commit for
# docker/eco-dev-llvm-git.Dockerfile to check.
#
# Build with:
#   C=8d4fc8f1d17e64e1826346a0230a87b50ec371e4
#   docker build -f docker/llvm-debian-git.Dockerfile \
#     --build-arg LLVM_COMMIT=$C -t eco-llvm-debian-git:$C .
# ============================================================
FROM debian:bookworm
ARG DEBIAN_FRONTEND=noninteractive
ARG LLVM_COMMIT

RUN case "${LLVM_COMMIT}" in \
      *[!0-9a-f]*|"") ok=0 ;; \
      *) [ "${#LLVM_COMMIT}" -eq 40 ] && ok=1 || ok=0 ;; \
    esac \
 && if [ "$ok" != 1 ]; then \
        echo "FATAL: pass --build-arg LLVM_COMMIT=<40 lowercase hex digits>, got '${LLVM_COMMIT}'" >&2; \
        exit 1; \
    fi

LABEL org.opencontainers.image.description="eco LLVM/MLIR builder at llvm-project ${LLVM_COMMIT}"
LABEL org.eco.llvm.commit="${LLVM_COMMIT}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libtinfo-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

# A shallow fetch of one commit (GitHub serves any reachable commit by hash);
# the rev-parse check makes the checkout prove it is that commit.
WORKDIR /src
RUN git init -q llvm-project \
 && cd llvm-project \
 && git remote add origin https://github.com/llvm/llvm-project.git \
 && git fetch -q --depth=1 origin "${LLVM_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "${LLVM_COMMIT}"

# Same configuration as docker/llvm-debian.Dockerfile, so the LLVM version is
# the only difference between the two images.
WORKDIR /src/llvm-project
RUN cmake -S llvm -B build -G Ninja \
      -DLLVM_ENABLE_PROJECTS="mlir" \
      -DLLVM_ENABLE_RUNTIMES="libunwind" \
      -DLLVM_TARGETS_TO_BUILD="Native;NVPTX;AMDGPU" \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_ENABLE_RTTI=ON \
      -DMLIR_ENABLE_CMAKE_PACKAGE=ON \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DMLIR_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_PARALLEL_LINK_JOBS=1 \
      -DLLVM_PARALLEL_COMPILE_JOBS=4 \
      -DLLVM_ENABLE_ZLIB=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_C_FLAGS="-march=x86-64-v3 -mtune=generic" \
      -DCMAKE_CXX_FLAGS="-march=x86-64-v3 -mtune=generic" \
      -DLLVM_USE_LINKER=lld \
      -DCMAKE_INSTALL_PREFIX=/opt/llvm-mlir \
 && cmake --build build \
 && cmake --install build \
 && printf '%s\n' "${LLVM_COMMIT}" > /opt/llvm-mlir/ECO_LLVM_COMMIT \
 && echo "Built LLVM $(/opt/llvm-mlir/bin/llvm-config --version) at ${LLVM_COMMIT}"
