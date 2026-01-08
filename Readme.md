# Elm Runtime in C

## Building with Docker (recommended for reproducible builds)

The Dockerfile provides all build dependencies in a reproducible environment.

### Prerequisites

Follow the advice here on installing Docker:
- [Install Docker](https://docs.docker.com/engine/install/debian/)
- [Configure non-root users](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user)

To confirm Docker is working correctly, run these commands (`newgrp docker` only
needs to be run if you are not logging out and back in again):

    newgrp docker
    docker run hello-world

### Build the Docker image

    docker build -t eco-runtime-build .

### Build the project using Docker

To configure and build the project in one step:

    docker run --rm -v "$PWD":/work eco-runtime-build

To run an interactive session inside the container for development, recommend creating
a named docker volume to preserve your home directory across sessions:

    docker volume create eco-dev-home
    docker run -it --rm -v "$PWD":/work -v eco-dev-home:/home/dev eco-runtime-build bash

To pass an OpenAI API key (for AI-assisted development tools), use the `-e` flag:

    docker run -it --rm -v "$PWD":/work -v eco-dev-home:/home/dev -e OPENAI_API_KEY="sk-proj-abc123..." eco-runtime-build bash

Or export it first and pass it through:

    export OPENAI_API_KEY="sk-proj-abc123..."
    docker run -it --rm -v "$PWD":/work -v eco-dev-home:/home/dev -e OPENAI_API_KEY eco-runtime-build bash

Inside the container, you can configure and build manually:

    cmake --preset ninja-clang-lld-linux
    cmake --build build

### Run tests using Docker

    docker run --rm -v "$PWD":/work eco-runtime-build bash -c "cmake --preset ninja-clang-lld-linux && cmake --build build && ./build/test/test"

## To work directly on a Debian or other apt-based Linux host

Install the following packages:

    sudo apt install clang lld ninja-build cmake ccache

A CMake preset configuration to build with ninja, clang and lld exists in
`CMakePresets.json`. Set up the build in this project with:

    cmake --preset ninja-clang-lld-linux

## Convenience Build Targets

After configuring with a preset, these convenience targets are available:

| Target | Description |
|--------|-------------|
| `check` | Incremental build + run tests |
| `run-tests` | Run tests only (no build) |
| `rebuild` | Clean + rebuild (no tests) |
| `full` | Clean + rebuild + run tests |

### Build and test (most common)

    cmake --build build --target check

### Run tests only

    cmake --build build --target run-tests

### Full clean rebuild and test

    cmake --build build --target full

### Filter tests by name

Use the `TEST_FILTER` environment variable with any test target:

    TEST_FILTER=elm cmake --build build --target check
    TEST_FILTER=String cmake --build build --target run-tests

### Clean rebuild without tests

    cmake --build build --target rebuild

## Running Tests Directly

For more control over test execution, run the test binary directly:

    ./build/test/test                    # Run all tests
    ./build/test/test --filter elm       # Filter by name
    ./build/test/test -n 1000            # Run 1000 tests
    ./build/test/test --seed 42          # Reproducible run
    ./build/test/test --max-size 500     # Higher complexity tests
