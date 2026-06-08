See [docs/getting-started.md](docs/getting-started.md).
# eco

eco is a native compiler and runtime for the [Elm](https://elm-lang.org/) 
programming language. Eco compiles Elm to native x86 binaries via MLIR and 
LLVM. The compiler front-end is itself written in Elm. There is a C++ backend 
for the MLIR and LLVM portion.

## Status

The overall status of the 0.1.0 release is alpha, reflecting the immaturity of 
the code at this time. There will be bugs (please find some!), possible ever 
severe ones. The bundled kernel IO code is an internal compile API exposed for
convenience; experiment with it but don't get too comfortable and don't rely
on it. A more complete set of IO APIs will follow and replace this API.

The full pipeline works today: Elm source compiles through a typed AST,
whole-program monomorphisation and optimisation, a custom MLIR dialect, and
LLVM down to native x86 binaries (AOT) or JIT execution, backed by a
generational garbage collector and effect-manager runtime. Linux x86_64 only.

The compiler is capable of building itself, which is a complex 160K LOC 
program, which goes along way towards proving the implementation is real-world
capable.

## Documentation

- [Getting Starged](docs/getting-started.md) - Getting started with the release bundle.
- [Building](docs/building.md) — Docker images, distribution bundles, the dev
  environment, CMake presets, and building on a Linux host.
- [Testing](docs/testing.md) — the elm-test, end-to-end, and stress suites.
- [Bootstrap](docs/bootstrap.md) — the 9-stage self-compilation pipeline.
- [Build targets](docs/build-targets.md) — reference for every CMake target.

## Getting Started

Dowload a Release from [eco-compiler Github repo](https://github.com/eco-lang/eco-compiler), 
then follow the getting started instructions.

See [docs/getting-started.md](docs/getting-started.md).

## Development Environment

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

## Acknowledgements and Lineage

The Eco compiler frontend is forked from
[Guida](https://github.com/guida-lang/compiler), an Elm compiler port. Guida is
itself a port of the original [Elm compiler](https://github.com/elm/compiler)
by Evan Czaplicki.
