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
RUN git clone --depth=1 --single-branch --branch "llvmorg-${LLVM_VERSION}" https://github.com/llvm/llvm-project.git

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
ARG NODE_VERSION=22

LABEL org.opencontainers.image.description="eco-runtime development environment"
LABEL org.opencontainers.image.source="https://github.com/eco-runtime/eco-runtime"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libxml2-dev \
    gosu curl libcmark-dev ccache \
    less \
    # Debugging and profiling tools (essential for GC development)
    gdb lldb linux-perf strace \
    # Code quality tools
    clang-format clang-tidy \
    # Developer convenience
    ripgrep fd-find vim-tiny bash-completion man-db jq time \
    # Locale support
    locales \
 && rm -rf /var/lib/apt/lists/* \
 # Configure locale
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen

# Install Node.js for Guida compiler builds
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Installed LLVM/MLIR
COPY --from=builder /opt/llvm-mlir /opt/llvm-mlir

# Install RapidCheck from source (not available in apt)
# RapidCheck is used for property-based testing
RUN git clone --depth=1 https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
    && cd /tmp/rapidcheck \
    && cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
    && cmake --build build \
    && cmake --install build \
    && rm -rf /tmp/rapidcheck

# Install Claude CLI
COPY ./install_claude.sh .
RUN ./install_claude.sh && rm ./install_claude.sh

# Install crag for knowledge base queries.
COPY ./crag_0.1.0_amd64.deb .
RUN dpkg --install ./crag_0.1.0_amd64.deb && rm ./crag_0.1.0_amd64.deb

# Install uv (Python package manager from Astral) system-wide
ENV UV_INSTALL_DIR="/usr/local/bin"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Workspace
WORKDIR /work

# Shell aliases and bash completion
RUN echo 'alias ll="ls -la"' >> /etc/bash.bashrc \
 && echo 'alias rg="rg --smart-case"' >> /etc/bash.bashrc \
 && echo 'alias fd="fdfind"' >> /etc/bash.bashrc \
 && echo '[ -f /etc/bash_completion ] && . /etc/bash_completion' >> /etc/bash.bashrc

# Add entrypoint script
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Locale configuration
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ccache configuration for faster incremental builds
ENV CCACHE_DIR=/work/.ccache
ENV CCACHE_MAXSIZE=5G

# Helpful defaults for downstream builds; entrypoint also exports these.
ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV LD_LIBRARY_PATH=/opt/llvm-mlir/lib
# ccache wrappers first in PATH for transparent caching
ENV PATH=/usr/lib/ccache:/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV CC=clang
ENV CXX=clang++

# Expose serena dashboard port
EXPOSE 24282

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]