# Building on macOS

Eco builds natively on macOS — both the front-end bootstrap and the full
runtime + AOT pipeline. Apple Silicon (`arm64`) is the supported target;
Intel Macs (`x86_64`) build with the same instructions but are not yet
verified in CI.

The Mach-O AOT output uses the system linker (`ld64`) and the macOS SDK
directly. The static-musl distribution path documented in
[`docs/building.md`](building.md) does NOT apply: macOS forbids static
linking `libSystem` and guarantees ABI stability of its system dylibs, so
the bundle dynamically links `libSystem` / `libc++` / `libcurl` / `libz`
from the SDK and statically links only Eco's own archives plus a small
set of dependencies the SDK doesn't carry (`libzip`, `libssl`,
`libcrypto`).

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
brew install cmake ninja node pnpm llvm@21 openssl@3 gnu-time pkgconf ccache
brew install rapidcheck    # required by the runtime test harness
```

| Package | Why |
|---|---|
| `cmake`, `ninja` | Build driver. CMake ≥ 3.20. |
| `node`, `pnpm` | Node 22+, used by the Stage 1–5 bootstrap (pure JS). |
| `llvm@21` | LLVM 21.1.8 + MLIR (brew bottle, ~minutes). The aggregate `libLLVM` / `libMLIR` dylibs carry every backend incl. AArch64. |
| `openssl@3` | The vendored libzip's `zip_crypto_openssl.c` references EVP_*; `Http.cpp` uses SHA1. Keg-only at `/opt/homebrew/opt/openssl@3/`. |
| `gnu-time` | The bootstrap's stage timing logs invoke GNU time as `gtime`. |
| `pkgconf` | Kernel-side curl/openssl probes. |
| `ccache` | Optional, dramatically speeds up rebuilds. |
| `rapidcheck` | Used by the runtime test harness (`ecor`). |

`libzip` is intentionally **not** installed via brew — it's vendored via
FetchContent on macOS so the AOT bundle ships its own `libzip.a` without
a `/opt/homebrew` runtime dep.

`brew install llvm@21` warns about a conflict with `llvm@18` if the latter
is preinstalled. Ignore the warning — the build uses absolute keg paths
via `CMAKE_PREFIX_PATH=/opt/homebrew/opt/llvm@21`, never `brew link`.

## CMake presets

Two macOS-specific presets:

| Preset | Build dir | Purpose |
|---|---|---|
| `mac-frontend` | `build/` | Front-end only. Configures `compiler/` via `ECO_FRONTEND_ONLY=ON`; pure Node/Elm bootstrap through Stage 5 (eco-compiler.mlir). No LLVM/MLIR / runtime / kernels / tests. Fast (~4 min on a clean build). |
| `mac-build` | `build/` | Full configure: runtime, kernels, tests, compiler. LLVM/MLIR from brew `llvm@21`. AppleClang + ld64 (no lld). |

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

The bundle is self-contained — `eco`'s runtime resolves project
archives via `<exe>/../lib/eco-runtime/project/` (same code path as
Linux), so any extraction prefix works.

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
share/eco/examples/hello/              # starter project
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
cd share/eco/examples/hello
../../bin/eco make src/Hello.elm --output=hello
file hello
# hello: Mach-O 64-bit executable arm64
./hello
# Hello, World!
```

The first `eco make` invocation pulls a few packages from the Elm package
registry into `~/.eco/` (the package cache). Subsequent builds are
incremental.

## CI workflows

The macOS port is exercised by a single consolidated GitHub Actions
workflow under `.github/workflows/`:

| Workflow | What it checks (cheap → expensive, fail-fast) |
|---|---|
| `mac-aot` | Full configure (`mac-build`); front-end Stages 1-5; the elm-tests suite; runtime + JIT E2E test binary; the full Stage 9 bootstrap (`--target eco`); Mach-O verification (`file` + `codesign -dv` + `--help`); CPack bundle; and a self-contained bundle smoke-test. |

`mac-aot` runs on the free `macos-15` (arm64, M-class) hosted runner.
It supersedes the former `mac-bootstrap` (front-end) and `mac-runtime`
(JIT) workflows, which were folded in as gateway steps so a single run
both tests and ships — and so a push installs LLVM via brew once, not
three times.
Private repos burn macOS minutes at 10×; the free tier covers public
repos like this one without metering.

## Caveats and follow-ups

The following are NOT yet supported on macOS:

- **`x86_64-apple-darwin`.** The code is platform-conditioned on
  `__aarch64__` for the GC's 16 KiB page size and the codegen CPU
  (`apple-m1`); Intel host builds will configure but are not in CI.
- **`.dylib` / `.node` outputs.** `linkExecutableDarwin()` currently
  errors on `sharedLib`; the Stage D `LinkProfile::GlibcBundleShared`
  refactor has no Mach-O counterpart yet.
- **CommonCrypto for SHA + libzip.** `Http.cpp`'s `SHA1()` and the
  vendored libzip's crypto backend both pull in OpenSSL; the elegant
  alternative is `CC_SHA1` + `ENABLE_COMMONCRYPTO`. Replacing them
  removes the brew `openssl@3` dep entirely.
- **Notarized `.pkg` / Homebrew formula.** The v1 bundle is the
  tarball; both packaging formats are deferred.
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
