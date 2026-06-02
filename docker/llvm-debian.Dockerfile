# ============================================================
# Builder image for LLVM + MLIR (Debian variant)
# ============================================================
# Built once, then consumed by the main /work/Dockerfile via
#   ARG LLVM_IMAGE=eco-llvm-debian:21.1.4
#   FROM ${LLVM_IMAGE} AS llvm
#   COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir
#
# Build with:
#   docker build -f docker/llvm-debian.Dockerfile -t eco-llvm-debian:21.1.4 .
# Bump the tag whenever LLVM_VERSION changes.
# ============================================================
FROM debian:bookworm
ARG DEBIAN_FRONTEND=noninteractive
ARG LLVM_VERSION=21.1.4
ARG CMAKE_BUILD_PARALLEL_LEVEL=24

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libtinfo-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth=1 --single-branch --branch "llvmorg-${LLVM_VERSION}" https://github.com/llvm/llvm-project.git

WORKDIR /src/llvm-project
RUN cmake -S llvm -B build -G Ninja \
      -DLLVM_ENABLE_PROJECTS="mlir" \
      -DLLVM_ENABLE_RUNTIMES="libunwind" \
      -DLLVM_TARGETS_TO_BUILD="Native;NVPTX;AMDGPU" \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_ENABLE_RTTI=ON \
      -DMLIR_ENABLE_CMAKE_PACKAGE=ON \
      -DLLVM_ENABLE_ZLIB=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DLLVM_USE_LINKER=lld \
      -DCMAKE_INSTALL_PREFIX=/opt/llvm-mlir \
 && cmake --build build \
 && cmake --install build
