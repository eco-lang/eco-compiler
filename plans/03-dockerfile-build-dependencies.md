# Plan: Create Dockerfile for Build Dependencies

**Related PLAN.md Section**: §5.1.3 Build System & Packaging

## Objective

Create a Dockerfile that encapsulates all build dependencies for reproducible builds of the eco-runtime project.

## Background

From PLAN.md §5.1.3:
> Create Dockerfile encapsulating all build dependencies

The project uses:
- C++20 (clang recommended per CMake presets)
- CMake 3.x
- Ninja build system
- RapidCheck for property-based testing
- lld linker

## Tasks

### 1. Analyze Current Build Requirements

Read these files to understand build dependencies:
- `CMakeLists.txt` - main build configuration
- `CMakePresets.json` - build presets showing compiler/linker requirements
- `test/CMakeLists.txt` - test dependencies

### 2. Create Dockerfile

Create `Dockerfile` at project root with:

```dockerfile
# Base image: Use a recent Ubuntu or Debian for good C++20 support
FROM ubuntu:24.04

# Install build essentials
RUN apt-get update && apt-get install -y \
    clang \
    lld \
    cmake \
    ninja-build \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install RapidCheck from source (not in apt)
RUN git clone https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
    && cd /tmp/rapidcheck \
    && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build \
    && cmake --install build \
    && rm -rf /tmp/rapidcheck

# Set working directory
WORKDIR /workspace

# Default command: configure and build
CMD ["bash", "-c", "cmake --preset ninja-clang-lld-linux && cmake --build build"]
```

### 3. Create .dockerignore

Create `.dockerignore` to exclude build artifacts:
```
build/
.git/
*.o
*.a
```

### 4. Test the Dockerfile

Verify with:
```bash
docker build -t eco-runtime-build .
docker run -v $(pwd):/workspace eco-runtime-build
```

### 5. Document Usage

Add a section to the Dockerfile or create `docker/README.md` explaining:
- How to build the image
- How to run builds inside the container
- How to run tests inside the container

## Success Criteria

1. `docker build -t eco-runtime-build .` succeeds
2. `docker run -v $(pwd):/workspace eco-runtime-build` builds the project
3. Tests can be run inside the container: `docker run -v $(pwd):/workspace eco-runtime-build ./build/test/test`

## Files to Create/Modify

- **Create**: `Dockerfile`
- **Create**: `.dockerignore`
- **Optional**: `docker/README.md`

## Estimated Complexity

Low - straightforward Docker setup with known dependencies.
