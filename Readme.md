# Eco

A native compiler and runtime for the [Elm](https://elm-lang.org/) programming
language. Eco compiles Elm to native x86 binaries via MLIR and LLVM. The
compiler itself is written in Elm.

## Status

The full pipeline works today: Elm source compiles through a typed AST,
whole-program monomorphisation and optimisation, a custom MLIR dialect, and
LLVM down to native x86 binaries (AOT) or JIT execution, backed by a
generational garbage collector and effect-manager runtime. Linux x86_64 only.

Pre-0.1.0. The remaining milestone is bootstrapping — the compiler compiling
itself to native code — which is in progress.

## Documentation

- [Building](docs/building.md) — Docker images, distribution bundles, the dev
  environment, CMake presets, and building on a Linux host.
- [Testing](docs/testing.md) — the elm-test, end-to-end, and stress suites.
- [Bootstrap](docs/bootstrap.md) — the 9-stage self-compilation pipeline.
- [Build targets](docs/build-targets.md) — reference for every CMake target.

## Quick Start

The recommended path is the Docker dev image, which bundles LLVM/MLIR, the C++
toolchain, and the Elm tooling. Build the base and dev images (one-off,
~30–60 min for LLVM), then build and test:

```bash
# Build the LLVM/MLIR base and the dev image (see docs/building.md for detail).
docker build -f docker/llvm-debian.Dockerfile -t eco-llvm-debian:21.1.4 .
docker build -f docker/eco-dev.Dockerfile -t eco-dev .

# Configure and run the full build + test suite inside the image.
docker run --rm -v "$PWD":/work eco-dev bash -c \
  "cmake --preset build && cmake --build build --target full"
```

Once the compiler is bootstrapped, compile and run an Elm program with the
unified `eco` binary — a drop-in replacement for `elm make`:

```bash
cd examples
eco make src/Hello.elm --output=hello   # → native ELF executable
./hello                                  # → Hello World!
```

See [docs/building.md](docs/building.md) for a Linux-host build,
[docs/bootstrap.md](docs/bootstrap.md) for producing the native `eco`, and
[docs/testing.md](docs/testing.md) for the test suites.

## Acknowledgements

The Eco compiler frontend is forked from
[Guida](https://github.com/guida-lang/compiler), an Elm compiler port. Guida is
itself a port of the original [Elm compiler](https://github.com/elm/compiler)
by Evan Czaplicki.
