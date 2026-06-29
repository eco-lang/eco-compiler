# Building eco on Windows

Status: **supported** on Windows x86_64 (plans/build-on-windows.md). The
full self-hosted chain builds end-to-end and produces the unified
`eco.exe` (Stages 6 → 7 → 8 byte-equal `.mlir` fixed point → 9), packaged
as `eco-<ver>-x86_64-windows.zip`. The whole chain is gated in CI by the
single [`win-aot.yml`][win-aot] workflow — front-end Stages 1–5, the
elm-tests suite, runtime + JIT E2E, the Stage 6 → 9 AOT self-host chain,
and the unified bundle smoke-tested with `eco.exe --help` — backed by
[`win-llvm-build.yml`][win-llvm-build], the cached LLVM-MSVC base-image
warmer. (`win-aot` supersedes the former `win-bootstrap` + `win-runtime`
workflows, folded in as gateway steps.) See
[Known limitations](#known-limitations-v1) for the pieces still deferred
behind explicit gates.

## Prerequisites

- **Windows 10/11 x86_64** with at least 16 GB RAM and 30 GB free disk.
- **Visual Studio Build Tools 2022 (MSVC 14.4+) + Windows SDK 10.0.26100**.
  clang-cl uses these for headers, libs and `ml64.exe`. Installing the
  full *Desktop development with C++* workload is the simplest path; the
  Build Tools alone are sufficient.
- **CMake ≥ 3.20 + Ninja** — both ship with VS Build Tools' "Visual C++
  build tools" component, or `choco install cmake ninja`.
- **Node 22+ and pnpm** — `choco install nodejs-lts` then
  `npm install -g pnpm`.
- **PowerShell 5.1+** or pwsh 7+ — used for the toolchain extraction step
  in `compiler/cmake/toolchain.cmake`.
- **LLVM 21.1.8 + MLIR** built from source — see [LLVM build](#llvm-build)
  below.

## Open a Developer Command Prompt

clang-cl needs the MSVC environment variables `INCLUDE`, `LIB`,
`LIBPATH`, plus `ml64.exe` on `PATH`. The simplest fix is to launch
**x64 Native Tools Command Prompt for VS 2022** (or the equivalent
PowerShell shortcut). All `cmake --preset win-*` and `cmake --build`
commands below should run from that prompt.

If you prefer the regular Windows Terminal, source `vcvarsall.bat x64`
once per session:

```powershell
& "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
```

## LLVM build

The Windows port pins **LLVM 21.1.8 with MLIR**, X86 backend only, Release,
static MSVC runtime. The `experiments/win-llvm-build/build.ps1` script is
the source of truth — invoke it directly, or copy its `cmake` invocation
into your own script. The build takes ~2-4 h on a 4-vCPU laptop; the
resulting install tree is ~2.5 GB.

```powershell
# From a Developer Command Prompt:
cd path\to\eco-compiler
$env:LLVM_INSTALL_DIR = "C:\llvm-mlir"   # default; override as needed
experiments\win-llvm-build\build.ps1
```

Set `LLVM_DIR=C:\llvm-mlir` (or your custom prefix) in the environment
before running the `win-build` preset so CMake's `CMAKE_PREFIX_PATH`
resolves to it.

## Configure & build

The presets ([`CMakePresets.json`][presets]) provide two Windows entry
points:

- `win-frontend` — Stages 1–5 only (`ECO_FRONTEND_ONLY=ON`). Pure
  Node/Elm; no LLVM/MLIR, runtime, kernels or tests. Useful for hacking
  on the compiler itself.
- `win-build` — full configure: runtime, kernels, codegen, tests,
  compiler. Requires the LLVM install tree from the previous step.

```powershell
# Front-end only:
cmake --preset win-frontend
cmake --build build --target eco-compiler-mlir

# Full build:
$env:LLVM_DIR = "C:\llvm-mlir"
cmake --preset win-build
cmake --build build --target eco          # Stage 9 unified eco.exe
```

The full build's Stage 9 output is `build\compiler\build-kernel\bin\eco.exe`
— the unified front-end + back-end compiler, self-hosted through the
Stage 8 byte-equal `.mlir` fixed point.

> **Note (Win64 paths):** the C++ `File` kernel hands paths back to the Elm
> compiler in forward-slash form (`std::filesystem::path::generic_string()`),
> since the Elm path code (`Utils/Main.elm` `fp*`) splits on `/`. App-data
> lookups use `APPDATA`/`USERPROFILE` (Windows has no `HOME`). If you extend
> the File kernel, keep returned paths forward-slash-normalized.

## Package the distributable bundle (ZIP)

CPack produces the self-contained `eco-<ver>-x86_64-windows.zip` (the same
artifact `win-aot.yml` ships):

```powershell
cmake --build build --target eco          # ensure Stage 9 eco.exe is built
cmake --build build --target package      # CPack ZIP (BundleWindows component)
Get-ChildItem build\eco-*.zip
```

The archive contains `bin\eco.exe`, the project `.lib` archives under
`lib\eco-runtime\project\` (including the vendored `libcurl_static` with
schannel TLS, `libzip` and `zlib` — no OpenSSL), and the kernel sources +
examples under `share\eco\`. It is self-contained: AOT outputs link against
those archives plus the static `/MT` CRT and OS import libs, so no VC++
redistributable is required.

## Run the tests

```powershell
# Elm front-end test suite (compiler/tests/):
cmake --build build --target elm-tests

# C++ JIT E2E tests (after a `win-build` configure):
cmake --build build --target test
.\build\test\test.exe
```

`elm-test-rs` exits 2 ("INCOMPLETE") for the compiler's one intentional
`Test.skip`; the CI accepts that as PASS iff zero tests actually failed,
and the same check applies locally.

## Known limitations (v1)

The Windows port is staged across the plan's W1–W5 milestones; the
following are *not yet implemented* in v1 and surface as runtime errors
when invoked:

- **`Eco.Process.spawn` / `spawnProcess`** — returns `ENOSYS`. Real
  CreateProcessW + pipe plumbing is plan item W2 #9.
- **Symbolic links via `file(CREATE_LINK ... SYMBOLIC)`** — replaced by
  NTFS junctions (`mklink /J`) which require no privileges. See
  `cmake/EcoCreateDirLink.cmake`.
- **`ecor` allocator test runner** — POSIX-only (`getopt_long`,
  `popen("addr2line")`); the test/JIT/AOT suites cover the same GC paths
  on Windows.

[win-aot]: ../.github/workflows/win-aot.yml
[win-llvm-build]: ../.github/workflows/win-llvm-build.yml
[presets]: ../CMakePresets.json
