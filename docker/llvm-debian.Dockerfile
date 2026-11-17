# ============================================================
# LLVM + MLIR for eco's glibc builds (Debian), at the llvm-project commit
# deps/versions.env pins (LLVM_COMMIT): the commit Modular MAX pins, so eco
# and MAX share one LLVM/MLIR. Modular's own patches on top of that commit
# (mostly AMDGPU/NVPTX codegen and lldb) are not applied.
#
# Consumed by docker/eco-dev.Dockerfile, which copies /opt/llvm-mlir out of
# it. The final stage holds nothing else, so the image is just the install
# tree; /opt/llvm-mlir/ECO_LLVM_COMMIT records the commit for eco's CMake
# check (cmake/EcoLlvmPin.cmake) and the image label for dev.sh.
#
# CI builds and publishes it (the llvm-build workflow) as
#   $(scripts/deps.sh artifact debian)
# i.e. ghcr.io/eco-lang/eco-llvm-debian:<commit>-<hash of this file>;
# local-dev/build-images.sh pulls that, or builds it with --local:
#   docker build -f docker/llvm-debian.Dockerfile \
#     --build-arg LLVM_COMMIT=$(scripts/deps.sh get LLVM_COMMIT) \
#     -t "$(scripts/deps.sh artifact debian)" .
# LLVM_COMMIT has no default, so a build without it fails rather than guess.
# ============================================================
FROM debian:bookworm AS build
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

# Only the install tree: consumers COPY /opt/llvm-mlir and nothing else.
FROM scratch
ARG LLVM_COMMIT
LABEL org.opencontainers.image.description="eco's LLVM/MLIR (Debian glibc) at llvm-project ${LLVM_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/eco-lang/eco-compiler"
LABEL org.eco.llvm.commit="${LLVM_COMMIT}"
COPY --from=build /opt/llvm-mlir /opt/llvm-mlir
