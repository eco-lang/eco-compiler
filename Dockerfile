# ============================================================
# Builder stage: build & install LLVM + MLIR
# ============================================================
FROM debian:bookworm AS builder
ARG DEBIAN_FRONTEND=noninteractive
ARG LLVM_VERSION=21.1.4
ARG CMAKE_BUILD_PARALLEL_LEVEL=24

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libtinfo-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth=1 --branch "llvmorg-${LLVM_VERSION}" https://github.com/llvm/llvm-project.git

WORKDIR /src/llvm-project
RUN cmake -S llvm -B build -G Ninja \
      -DLLVM_ENABLE_PROJECTS="mlir" \
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

# ============================================================
# Runtime stage: tools + installed MLIR, non-root entrypoint
# ============================================================
FROM debian:bookworm
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libxml2-dev \
    gosu curl \
 && rm -rf /var/lib/apt/lists/*

# Installed LLVM/MLIR
COPY --from=builder /opt/llvm-mlir /opt/llvm-mlir

# Install RapidCheck from source (not available in apt)
# RapidCheck is used for property-based testing
RUN git clone https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
    && cd /tmp/rapidcheck \
    && cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
    && cmake --build build \
    && cmake --install build \
    && rm -rf /tmp/rapidcheck

# Install Claude CLI
COPY ./install_claude.sh ./install_claude.sh
RUN ./install_claude.sh

# Workspace
WORKDIR /work

# Add entrypoint script
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Helpful defaults for downstream builds; entrypoint also exports these.
ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV LD_LIBRARY_PATH=/opt/llvm-mlir/lib
ENV PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV CC=clang
ENV CXX=clang++

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]