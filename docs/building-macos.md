# Building on macOS

Eco builds natively on macOS — both the front-end bootstrap and the full
runtime + AOT pipeline. Apple Silicon (`arm64`) on macOS 15.0 or later is
the supported target; Intel Macs are not supported.

The Mach-O AOT output uses the system linker (`ld64`) and the macOS SDK
directly. The static-musl distribution path documented in
[`docs/building.md`](building.md) does NOT apply: macOS forbids static
linking `libSystem` and guarantees ABI stability of its system dylibs, so
`eco` and the programs it builds dynamically link `libSystem` / `libc++` /
`libcurl` / `libz` from macOS and statically link everything else: LLVM and
MLIR (in `eco` only), Eco's own archives, and the dependencies macOS doesn't
carry (`libzip`, `libssl`, `libcrypto`). Nothing is loaded from Homebrew at
run time.

**Minimum macOS.** `CMAKE_OSX_DEPLOYMENT_TARGET` defaults to 15.0 in the
top-level `CMakeLists.txt`; it applies to `eco`, the bundled archives and
(via the target triple and `-mmacosx-version-min`) every program `eco make`
links. Every Apple Silicon Mac can run macOS 15. The `mac-aot` workflow
fails if anything shipped or linked needs a newer macOS
(`test/scripts/check-macho-floor.sh`).

## Using the bundle

Users need only the Xcode Command Line Tools (`xcode-select --install`),
which supply the linker and SDK `eco make` links against. `eco` finds them
through `xcrun` each time it links (`$SDKROOT` overrides the SDK), so the
bundle works wherever it is unpacked, with whichever Xcode or Command Line
Tools the Mac has. See [`docs/getting-started.md`](getting-started.md) for
installation.

## Prerequisites

### 1. Xcode Command Line Tools

```bash
xcode-select --install
```

The CLT supplies `ld64`, the macOS SDK (`/Applications/Xcode_*.app/.../MacOSX.sdk`
or `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`), and the
AppleClang frontend. Confirm:

```bash
xcrun -f clang             # → /usr/bin/clang (or under the active Xcode)
xcrun --show-sdk-path      # → an existing path to a MacOSX.sdk
```

### 2. Homebrew packages

```bash
brew install cmake ninja node pnpm openssl@3 gnu-time pkgconf ccache
brew install rapidcheck    # required by the runtime test harness
```

| Package | Why |
|---|---|
| `cmake`, `ninja` | Build driver. CMake ≥ 3.20. |
| `node`, `pnpm` | Node 22+, used by the Stage 1–5 bootstrap (pure JS). |
| `openssl@3` | TLS in `eco/system`, SHA1 in `Http.cpp`, and the vendored libzip's crypto. Its static `libssl.a` / `libcrypto.a` are linked into `eco` and into user programs, so the bundle does not need Homebrew at run time. |
| `gnu-time` | The bootstrap's stage timing logs invoke GNU time as `gtime`. |
| `pkgconf` | Kernel-side curl/openssl probes. |
| `ccache` | Optional, dramatically speeds up rebuilds. |
| `rapidcheck` | Used by the runtime test harness (`ecor`). |

`libzip` is intentionally **not** installed via brew — it's vendored via
FetchContent on macOS so the AOT bundle ships its own `libzip.a` without
a `/opt/homebrew` runtime dep.

### 3. LLVM/MLIR 21.1.8 (static)

`eco` links LLVM and MLIR statically from a pinned 21.1.8 install tree, the
same version as the Linux and Windows builds. Homebrew's `llvm@21` is not
used: it is built around its shared `libLLVM.dylib`, which a shipped `eco`
cannot rely on. Build the tree once (roughly an hour on an M-series Mac):

```bash
experiments/mac-llvm-build/build.sh     # → experiments/mac-llvm-build/out/llvm-install
export ECO_MAC_DEPS_DIR=$PWD/experiments/mac-llvm-build/out/llvm-install
```

The `mac-build` preset reads `ECO_MAC_DEPS_DIR` as its `CMAKE_PREFIX_PATH`.
CI builds the same tree in the `mac-llvm-build` workflow and caches it.

## CMake presets

Two macOS-specific presets:

| Preset | Build dir | Purpose |
|---|---|---|
| `mac-frontend` | `build/` | Front-end only. Configures `compiler/` via `ECO_FRONTEND_ONLY=ON`; pure Node/Elm bootstrap through Stage 5 (eco-compiler.mlir). No LLVM/MLIR / runtime / kernels / tests. Fast (~4 min on a clean build). |
| `mac-build` | `build/` | Full configure: runtime, kernels, tests, compiler. Static LLVM/MLIR 21.1.8 from `$ECO_MAC_DEPS_DIR`. AppleClang + ld64 (no lld). |

Both are gated on `${hostSystemName} == Darwin` so they only appear in
`cmake --list-presets` on macOS hosts.

## Quick start — front-end only

The fastest path to a working compiler.mlir (no native back-end):

```bash
cmake --preset mac-frontend
cmake --build build --target eco-boot-verify    # Stages 1–4b + JS fixed-point
cmake --build build --target eco-compiler-mlir  # Stage 5 → eco-compiler.mlir
cmake --build build --target elm-tests          # Elm test suite
```

After this, `build/compiler/build-kernel/bin/eco-compiler.mlir` exists
(~12 MB, the entire Eco compiler as MLIR), and the compiler's own Elm
tests have passed.

## Full build — runtime, AOT, and bundle

For the user-facing `eco` binary and a redistributable tarball:

```bash
cmake --preset mac-build
cmake --build build --target test               # JIT E2E test binary
./build/test/test                               # 1493 tests, ~6-8 min
cmake --build build --target eco                # Stage 9 — unified `eco`
cmake --build build --target package            # CPack TGZ
```

After `--target eco`, the unified binary is at
`build/compiler/build-kernel/bin/eco`. After `--target package`, the
bundle is at `build/eco-<version>-<arch>-darwin.tar.gz`.

The bundle smoke-test is straightforward:

```bash
mkdir -p /tmp/eco-install && tar -xzf build/eco-*-darwin.tar.gz -C /tmp/eco-install
/tmp/eco-install/bin/eco --help
```

The bundle is self-contained apart from the Command Line Tools — `eco`'s
runtime resolves project archives via `<exe>/../lib/eco-runtime/project/`
(same code path as Linux), so any extraction prefix works.

## Bundle layout

```
bin/
  eco                                  # the unified compiler (Stage 9)
lib/eco-runtime/project/
  libEco{Entry,Embed,NodeGlue,Runtime,NativeDriver}Static.a
  libElmKernel_*.a                     # 22 Elm kernel modules
  libEcoKernel_*.a                     # 9 Eco kernel modules
  libzip.a, libssl.a, libcrypto.a      # deps not in the SDK
share/eco/kernel/eco-kernel-cpp/       # Elm sources for `import Eco.*`
share/eco/examples/                    # example project (Hello, eco/system)
```

A typical bundle is ~30 MB compressed. Notable contrasts with the Linux
Stage C bundle:

- **No `crt/`.** `ld64` supplies Mach-O program startup; no user-supplied
  crt objects.
- **No `libc.a` / `libc++.a` / `libcurl.a` / `libz.a`.** The SDK provides
  `.tbd` stubs and the produced binary dynamically links the system
  dylibs — Apple's documented ABI contract.
- **No bundled linker.** Users must have Xcode Command Line Tools
  installed; CLT's `ld64` is the platform's contract.
- **No `glibc/` subtree.** Mach-O has no analogue.

Code signing is automatic: `ld64` applies an ad-hoc (linker-signed)
signature to every arm64 Mach-O it emits. Verify with:

```bash
codesign -dv bin/eco
# Format=Mach-O thin (arm64)
# CodeDirectory v=20400 ... flags=0x20002(adhoc,linker-signed)
# Signature=adhoc
```

A notarized `.pkg` and a Homebrew formula are tracked as follow-ups; the
v1 release is the tarball above.

## Running a sample program

```bash
cd share/eco/examples
../../bin/eco make src/Hello.elm --output=hello
file hello
# hello: Mach-O 64-bit executable arm64
./hello
# Hello World!
```

The first `eco make` invocation pulls a few packages from the Elm package
registry into `~/.eco/` (the package cache). Subsequent builds are
incremental.

## CI workflows

The macOS port is exercised by a single consolidated GitHub Actions
workflow under `.github/workflows/`:

| Workflow | What it checks (cheap → expensive, fail-fast) |
|---|---|
| `mac-llvm-build` | Builds the static LLVM/MLIR 21.1.8 tree (`experiments/mac-llvm-build/build.sh`, 2-3 h cold) and caches it; a weekly run keeps the cache warm. |
| `mac-aot` | Restores that tree; full configure (`mac-build`); front-end Stages 1-5; the elm-tests suite; runtime + JIT E2E test binary; the full Stage 9 bootstrap (`--target eco`); Mach-O verification (`file` + `codesign -dv` + `--help`); CPack bundle; a bundle smoke-test that builds `Hello.elm`; the macOS-floor and linked-library gate. Its `bundle-smoke` job then installs the bundle on a fresh runner with only the Command Line Tools (Xcode app and Homebrew LLVM/OpenSSL moved aside, clean `HOME`, minimal `PATH`) and builds and runs two programs. |

`mac-aot` runs on the free `macos-15` (arm64, M-class) hosted runner.
It supersedes the former `mac-bootstrap` (front-end) and `mac-runtime`
(JIT) workflows, which were folded in as gateway steps so a single run
both tests and ships.
Private repos burn macOS minutes at 10×; the free tier covers public
repos like this one without metering.

## Caveats and follow-ups

The following are NOT yet supported on macOS:

- **`x86_64-apple-darwin`.** Intel Macs are out of scope: the LLVM tree
  carries only the AArch64 backend, and the code is platform-conditioned
  on `__aarch64__` for the GC's 16 KiB page size and the codegen CPU
  (`apple-m1`).
- **Linking without the Command Line Tools.** A bundled `ld64.lld` plus
  generated `.tbd` stubs would remove the last prerequisite; see the
  follow-up in [`plans/mac-self-contained-bundle.md`](../plans/mac-self-contained-bundle.md).
- **`.dylib` / `.node` outputs.** `linkExecutableDarwin()` currently
  errors on `sharedLib`; the Stage D `LinkProfile::GlibcBundleShared`
  refactor has no Mach-O counterpart yet.
- **CommonCrypto for SHA + libzip.** `Http.cpp`'s `SHA1()` and the
  vendored libzip's crypto backend both pull in OpenSSL; the elegant
  alternative is `CC_SHA1` + `ENABLE_COMMONCRYPTO`. Replacing them
  would remove the brew `openssl@3` build dependency (eco/system's TLS
  also uses OpenSSL).
- **Notarized `.pkg` / Homebrew formula.** The v1 bundle is the
  tarball, ad-hoc signed only; downloaded with a browser it is
  quarantined and blocked by Gatekeeper (see
  [`docs/getting-started.md`](getting-started.md)). Both packaging
  formats are deferred.
- **Universal binaries.** AOT codegen targets the host arch only.

## Reference

- [`plans/build-on-mac.md`](../plans/build-on-mac.md) — design plan,
  per-milestone (M1-M5) checklist, dependency mapping vs Linux, and the
  E-M1 through E-M4 GitHub-runner experiments that backed each
  milestone.
- [`docs/building.md`](building.md) — Linux build, Docker images,
  static-musl distribution.
- [`docs/bootstrap.md`](bootstrap.md) — the 9-stage self-compilation
  pipeline.
- [`docs/testing.md`](testing.md) — elm-test, end-to-end, and stress
  test suites.
