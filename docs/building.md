# Building

The recommended path is the Docker dev image, which bundles LLVM/MLIR, the C++
toolchain, Node/pnpm, and the Elm test runner. To build directly on a Linux
host instead, see [Building on a Linux host](#building-on-a-linux-host) at the
end of this document.

## Docker Setup

The Docker setup is built from four images: two LLVM/MLIR base images (slow,
rebuilt only when `LLVM_VERSION` changes) and consumer images that
`COPY /opt/llvm-mlir` from a base.

```
eco-llvm-debian:21.1.8 ──► eco-dev                  (glibc dev shell)
eco-llvm-alpine:21.1.8 ─┬► eco-static               (static `eco` binary)
                        └► eco-static-dev:local     (musl dev shell)
```

### 1. Creating all the images

From `/work`:

```bash
# 1a. LLVM/MLIR base images (~30–60 min each, independent — can run in
#     parallel). Only re-run when LLVM_VERSION changes.
docker build -f docker/llvm-debian.Dockerfile -t eco-llvm-debian:21.1.8 .
docker build -f docker/llvm-alpine.Dockerfile -t eco-llvm-alpine:21.1.8 .

# 1b. Glibc dev image (needs eco-llvm-debian).
docker build -f docker/eco-dev.Dockerfile -t eco-dev .

# 1c. Static `eco` binary (FROM scratch; needs eco-llvm-alpine).
docker build -f docker/static-build.Dockerfile --target eco-static -t eco-static .

# 1d. Musl interactive dev image (needs eco-llvm-alpine).
docker build -f docker/static-dev.Dockerfile -t eco-static-dev:local .
```

Each consumer image (1b/1c/1d) only needs its corresponding base from 1a.

The static binary is fully static — zero shared-library dependencies, so it
runs on any Linux distribution. To extract and confirm it:

```bash
id=$(docker create eco-static); docker cp "$id:/eco" ./eco; docker rm "$id"
readelf -d ./eco | grep -c NEEDED        # expect 0
```

### 2. Creating the distribution bundles → `dist/`

The `eco-bundle` stage of `docker/static-build.Dockerfile` runs CPack to
produce the release archives — a self-contained `eco` plus the
`lib/eco-runtime/` tree (crt objects, static archives, bundled linker) it needs
for ahead-of-time linking. Building with `-o ./dist` exports them to the host
(the directory is created if absent; needs BuildKit, the default in Docker
23+):

```bash
docker build -f docker/static-build.Dockerfile --target eco-bundle -o ./dist .
```

This drops three files into `./dist/` (the `0.1.0` baseline comes from
`version.txt`):

| File | Format |
|------|--------|
| `eco-0.1.0-x86_64-linux-musl.tar.gz` | gzip tarball |
| `eco-0.1.0-x86_64-linux-musl.zip`    | zip archive |
| `eco_0.1.0_amd64.deb`                | Debian package |

**Overriding the version.** `version.txt` is the baseline. To stamp a different
version, pass `--build-arg ECO_VERSION=<v>` — it sets both the archive names
**and** the binary's `eco --version` string (via the CMake
`ECO_VERSION_OVERRIDE` knob):

```bash
docker build -f docker/static-build.Dockerfile --target eco-bundle \
    --build-arg ECO_VERSION=1.2.3 -o ./dist .
# → dist/eco-1.2.3-x86_64-linux-musl.{tar.gz,zip}, dist/eco_1.2.3_amd64.deb
```

The package set and filenames are defined by the CPack configuration in the
top-level `CMakeLists.txt`, all derived from the resolved version.

### 3. Running the dev image interactively

```bash
# Persistent home directory across sessions.
docker volume create eco-dev-home
docker run -it -e "TERM=xterm-256color" --rm \
    -v "$PWD":/work -v eco-dev-home:/home/dev eco-dev bash
```

The entrypoint detects the host uid/gid from the bind-mounted `/work` (or
`HOST_UID`/`HOST_GID`) and creates a matching user inside the container, so
files in `/work` stay correctly owned. The resolved user is granted
passwordless `sudo`.

For the musl dev image (`eco-static-dev:local`), add `--cap-add=SYS_PTRACE`
(or `--privileged`) so gdb/strace/perf can attach.

## CMake Setup

### Presets

Three presets cover the day-to-day workflow:

| Preset | Build dir | Purpose |
|---|---|---|
| `build` | `build/` | Everyday build — RelWithDebInfo, asserts on, GC stats on. The bootstrap target's home. |
| `dev` | `debug/` | Debug — full assertions, GC stats, kernel-debug stderr. Slow; reserve for diagnostics. |
| `release` | `build-static/` | Static musl — `-O2 -DNDEBUG`, no asserts, `--strip-all`. The shippable binary. |

```bash
cmake --preset build      # then: cmake --build build
cmake --preset dev        # then: cmake --build debug
cmake --preset release    # then: cmake --build build-static
```

Two options can be flipped on any preset rather than via a separate preset:

- `-DECO_USE_CCACHE=ON` — wrap C/C++ compiles with ccache.
- `-DECO_FRAME_POINTERS=ON` — preserve frame pointers (perf / flamegraph).

### Build and test

The `full` target is the workhorse: clean rebuild + the full E2E suite. Use it
after compiler changes.

```bash
# Full clean rebuild + run E2E tests (preferred after compiler changes)
cmake --build build --target full

# Incremental build + run E2E tests
cmake --build build --target check
```

For the complete testing story (elm-test, E2E, stress), see
[testing.md](testing.md). For the full list of build targets, see
[build-targets.md](build-targets.md).

## Bootstrap pipeline

Producing the self-hosted, native `eco` binary runs through a 9-stage
self-compilation chain. See [bootstrap.md](bootstrap.md) for the stages, their
test gates, and the single command that runs the whole pipeline.

## Building on a Linux host

```bash
sudo apt install clang lld ninja-build cmake ccache nodejs
corepack enable pnpm    # corepack ships with Node.js >= 16.9
```

The compiler frontend is written in Elm and built via a small Node.js runner.
The package manager is **pnpm** (not npm) — `compiler/.npmrc` sets
`ignore-scripts=true`, removing the install-time arbitrary-code-execution
surface from binwrap-style packages.

The Elm toolchain itself (`elm 0.19.1`, `elm-format`, `elm-test-rs`) is **not**
pulled from npm. CMake fetches those binaries with SHA256-pinned URLs from
upstream GitHub releases into `build/toolchain/bin/` (see
`compiler/cmake/toolchain.cmake`). You do not need to `npm install` them.

Then configure and build with any of the presets above:

```bash
cmake --preset build
cmake --build build --target full
```
