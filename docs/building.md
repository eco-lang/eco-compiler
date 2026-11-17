# Building

The recommended path is the Docker dev image, which bundles LLVM/MLIR, the C++
toolchain, Node/pnpm, and the Elm test runner. To build directly on a Linux
host instead, see [Building on a Linux host](#building-on-a-linux-host) at the
end of this document. For macOS and Windows hosts, see
[building-macos.md](building-macos.md) and
[building-windows.md](building-windows.md).

## Docker Setup

The Docker setup is built from two LLVM/MLIR base images and the consumer
images that `COPY /opt/llvm-mlir` from a base. The base images are built at the
llvm-project commit [`deps/versions.env`](../deps/versions.env) pins
(`LLVM_COMMIT`: the commit Modular MAX pins). The `llvm-build` workflow builds
each once per commit and recipe and publishes it to GHCR, named by
`scripts/deps.sh artifact debian|alpine`
(`ghcr.io/eco-lang/eco-llvm-<platform>:<commit>-<recipe hash>`), so a dev box
pulls it instead of building LLVM.

```
eco-llvm-debian:<commit>-<hash> ──► eco-dev                  (glibc dev shell)
eco-llvm-alpine:<commit>-<hash> ─┬► eco-static               (static `eco` binary)
                                 └► eco-static-dev:local     (musl dev shell)
```

### 1. Creating all the images

From `/work`:

```bash
# 1a + 1b. Pull the pinned LLVM images and build eco-dev and eco-local-dev
#     (--static adds the musl images; --local builds LLVM here instead of
#     pulling it, ~30-60 min per image). While the eco-lang packages are
#     private, log in first:
#       gh auth token | docker login ghcr.io -u <github user> --password-stdin
local-dev/build-images.sh --static

# 1c. Static `eco` binary (FROM scratch; needs the alpine LLVM). This makes an
#     image, not files on the host: for the release bundles in dist/, see
#     section 2 (--target eco-bundle -o ./dist).
docker build -f docker/static-build.Dockerfile \
  --build-arg LLVM_IMAGE="$(scripts/deps.sh artifact alpine)" \
  --target eco-static -t eco-static .
```

`build-images.sh` runs the chain in order: the LLVM image(s), then `eco-dev`
(with the LLVM image, its commit and the pinned uv as build arguments, none of
which has a default), then `eco-local-dev`, and with `--static`,
`eco-static-dev:local`. `local-dev/dev.sh` refuses to start an image whose LLVM
is not the pinned one, and CMake refuses a build tree configured against
another LLVM (`cmake/EcoLlvmPin.cmake`): after a pin moves, re-run
`build-images.sh` and delete old build trees.

### Moving a pin

`scripts/deps.sh` changes the versions, and nothing else needs editing by hand:

```bash
scripts/deps.sh max 26.8.0     # MAX, and (LLVM_FOLLOWS=max) LLVM to MAX's own pin
scripts/deps.sh check          # everything consistent? (CI runs this)
```

A MAX release that keeps its LLVM commit needs no LLVM build: push, and CI
re-syncs MAX. One that moves it starts the `llvm-build` workflow (hours,
unattended) and usually a few LLVM API fixes; log them in
[`docs/llvm-pins.md`](llvm-pins.md). See `plans/llvm-24-upgrade.md` §9.

**Optional: GenMC for the GC's weak-memory checks** (`test/genmc/`, target
`genmc-check`; not used by CI). GenMC is an opt-in layer on top of eco-dev, so the
standard image and CI do not depend on it. The builder image compiles a temporary
GCC 14 and GenMC on LLVM 19; rebuild it only when `docker/install-genmc.sh` changes
a pin (and bump the tag with it):

```bash
docker build -f docker/genmc.Dockerfile -t eco-genmc:0.19.0-llvm19 .
docker build -f docker/eco-dev-genmc.Dockerfile -t eco-dev-genmc .   # eco-dev + GenMC
```

Run `eco-dev-genmc` exactly as `eco-dev`.

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

This drops three files into `./dist/` (the `0.2.0` baseline comes from
`version.txt`):

| File | Format |
|------|--------|
| `eco-0.2.0-x86_64-linux-musl.tar.gz` | gzip tarball |
| `eco-0.2.0-x86_64-linux-musl.zip`    | zip archive |
| `eco_0.2.0_amd64.deb`                | Debian package |

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

**Numbered builds.** `docker/build-dist.sh` wraps the command above and stamps
each local build as `<version.txt>~b<N>.g<12-char hash>` (plus `.dirty` when
tracked files differ from HEAD), e.g. `0.2.0~b17.g1a2b3c4d5e6f`. `N` comes from
`BUILD_NUMBER` when set, otherwise from a local `.build-number` counter the
script increments. The `~` makes Debian sort these builds before the plain
release. CI uses the same format via `.github/scripts/eco-version.sh`, with `N`
the commit count; `publish-nightly.yml` rewrites the `~` in published asset
names (`-` for the archives, `.` for the `.deb`), since GitHub would otherwise
mangle it.

```bash
docker/build-dist.sh        # → dist/eco-0.2.0~b<N>.g<hash>-x86_64-linux-musl.tar.gz, ...
```

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

Seven configure presets exist (`cmake --list-presets`). Three cover the
day-to-day Linux workflow:

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

The other four are per-platform: `mac-build` / `mac-frontend` (see
[building-macos.md](building-macos.md)) and `win-build` / `win-frontend` (see
[building-windows.md](building-windows.md)). The `*-frontend` presets build
only bootstrap Stages 1–5, with no native back-end.

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

eco also needs its pinned LLVM/MLIR at `/opt/llvm-mlir` (on `CMAKE_PREFIX_PATH`).
The simplest source is the published image, which holds only that tree:

```bash
id=$(docker create "$(scripts/deps.sh artifact debian)" true)
sudo docker cp "$id:/opt/llvm-mlir" /opt/ && docker rm "$id"
```

and, for MAX, [uv](https://docs.astral.sh/uv/) at least at `UV_VERSION` from
`deps/versions.env` (without it, configure turns MAX off).

Then configure and build with any of the presets above:

```bash
cmake --preset build
cmake --build build --target full
```
