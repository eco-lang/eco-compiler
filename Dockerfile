# Dockerfile for eco-runtime build environment
# Provides all build dependencies for reproducible builds

FROM debian:bookworm

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build essentials and dependencies
RUN apt-get update && apt-get install -y \
    clang \
    lld \
    cmake \
    ninja-build \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

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

# Set working directory
WORKDIR /workspace

# Default command: configure and build the project
CMD ["bash", "-c", "cmake --preset ninja-clang-lld-linux && cmake --build build"]
