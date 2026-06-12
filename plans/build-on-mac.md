# Plan: Build Eco on macOS

## Goal

A working `eco` on macOS (Apple Silicon primary, Intel secondary): compiler
bootstrap, JIT E2E tests, and AOT compilation producing runnable Mach-O
executables. **Dynamic linking is the correct model on macOS** — unlike Linux,
the platform forbids static libSystem and guarantees ABI stability of system
dylibs, so the entire Stage A/B/C/D static-link apparatus
(`ECO_STATIC`, `ECO_STATIC_MUSL`, musl/glibc dual trees, vendored
libcurl/zlib) is *not needed* and stays Linux-only. One build profile
suffices: dynamic against libSystem/libc++/libcurl/libz from the macOS SDK,
with LLVM/MLIR and all Eco/kernel archives statically linked into `eco`
itself (as the `build` preset already does on Linux).

## Why macOS is the easier port

The runtime is POSIX throughout, and macOS is POSIX:

- `mmap`/`munmap` heap model in `runtime/src/allocator/Allocator.cpp`
  (reserve `PROT_NONE`, commit with `MAP_FIXED`) works unchanged on macOS.
  `MAP_NORESERVE` is a no-op there — harmless.
- pthreads (`eco_entry.cpp`, `eco_embed.cpp`), POSIX signals (`main.cpp`),
  `fork`/`execvp`/`pipe`/`waitpid` (`eco-kernel-cpp/src/eco/Process.cpp`),
  `stat`/`opendir`/`readdir` (`File.cpp`) — all native on macOS.
- LLVM libunwind **is** the macOS system unwinder (it originated at Apple),
  so `StackUnwind.cpp`'s `unw_getcontext`/`unw_step`/`UNW_REG_IP` usage works
  against the system library; `cmake/LLVMLibunwind.cmake` can short-circuit
  to "use system" on Darwin.
- The JIT's per-FDE `__register_frame` walk in `runtime/src/jit/EcoJIT.cpp`
  (registering each FDE individually, skipping CIEs) is exactly the macOS
  libunwind convention — the comment in that file already documents this.
  Likely works as-is.
- `EcoBackend.cpp:66` uses `sys::getDefaultTargetTriple()`, so codegen
  retargets to `arm64-apple-darwin` / `x86_64-apple-darwin` automatically.
- `elm-kernel-cpp/src/time/TimeExports.cpp` and
  `eco-kernel-cpp/src/eco/File.cpp` already carry `__APPLE__` branches.

What does NOT carry over (the actual work) is everything ELF- or
Linux-procfs-specific, plus the AOT link driver.

## Work items

### M1 — Toolchain + configure on macOS (x86_64 first, or arm64 under Rosetta-fallback rules)

1. **`compiler/cmake/toolchain.cmake`: per-platform download table.**
   Upstream prebuilts exist for both mac architectures (verified against
   the GitHub releases, 2026-06):
   - elm 0.19.1: `binary-for-mac-64-bit.gz` (x86_64) and
     `binary-for-mac-64-bit-ARM.gz` (Apple Silicon — added to the 0.19.1
     release after the fact).
   - elm-format 0.8.7: `elm-format-0.8.7-mac-x64.tgz` and
     `elm-format-0.8.7-mac-arm64.tgz`.
   - elm-test-rs v3.0.1: `elm-test-rs_macos.tar.gz` and
     `elm-test-rs_macos-arm.tar.gz`.
   Key by `CMAKE_HOST_SYSTEM_NAME`/`CMAKE_HOST_SYSTEM_PROCESSOR`; keep the
   existing Linux URLs as the Linux branch, untouched. No Rosetta needed
   for the toolchain.
2. **node + pnpm**: already discovered via `find_program`; Homebrew installs
   work. The guida.js bootstrap (stages 1–5) is pure Node — cross-platform
   for free. `NODE_OPTIONS=--max-old-space-size=12000` works unchanged.
3. **LLVM/MLIR**: brew's `llvm` formula **confirmed** ships MLIR
   (`mlir` is in its `LLVM_ENABLE_PROJECTS`), but it is at LLVM **22.x**
   as of 2026-06 vs our pinned `llvmorg-21.1.4` — a real major-version
   skew. Options: (a) build from source on the mac with the recipe from
   `docker/llvm-alpine.Dockerfile` as `scripts/build-llvm-macos.sh`
   (pinned, matches Linux — preferred); (b) `brew install llvm@21` if a
   versioned keg exists; (c) accept brew 22.x and absorb any API churn.
   Start with (a) for determinism; (c) only as a quick-start.
4. **New CMake presets** in `CMakePresets.json`: `mac-dev`, `mac-build`
   (binaryDirs `debug`/`build` are fine — different machine — but use
   `condition: { type: equals, lhs: ${hostSystemName}, rhs: Darwin }` so
   presets are filtered per-OS and Linux presets gain the symmetric
   `Linux` condition). Compiler: AppleClang or brew clang; linker: ld64
   (drop `-fuse-ld=lld` on Darwin — ld64 is the default and correct;
   `ld64.lld` is an option later if ld64 misbehaves with
   `__llvm_stackmaps`).

### M2 — Runtime/host code: replace the ELF/procfs bits

Introduce small platform seams rather than scattering `#ifdef`s:

5. **Executable path discovery** — `/proc/self/exe` is read at **five**
   sites, not one: `EcoBootConfig.cpp:34`, `eco-kernel-cpp/src/eco/
   Runtime.cpp:31`, `runtime/src/main.cpp:143`, `eco_embed.cpp`, and
   `eco_entry.cpp:60`. Add one shared `currentExecutablePath()` helper
   (Darwin → `_NSGetExecutablePath` + `realpath`; Linux → existing
   readlink) and route all five through it.
6. **`eco_entry.cpp` includes `<elf.h>`/`<link.h>`** to walk the link map
   for symbol exports used by JIT external lookup. Darwin equivalent:
   `dlsym(RTLD_DEFAULT, name)` or `_dyld_*` APIs. Audit what the walk is
   actually for — if it only resolves runtime-exported symbols,
   `RTLD_DEFAULT` dlsym likely suffices and is simpler on both platforms.
7. **Stackmap section discovery**. On ELF the AOT runtime finds
   `.llvm_stackmaps`; on Mach-O the section is
   `__LLVM_STACKMAPS,__llvm_stackmaps`. Use
   `getsectiondata(&_mh_execute_header, "__LLVM_STACKMAPS",
   "__llvm_stackmaps", &size)` on Darwin. Audit all consumers found in:
   `StackMap.cpp`, `RuntimeExports.cpp`, `eco_entry.cpp`, `EcoJIT.cpp`.
8. **`backtrace()`**: `<execinfo.h>` exists on macOS — the existing
   `__has_include` guards already do the right thing. No work.
9. **Signals**: `SIGINT/SIGTERM/SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGPIPE`
   all exist on macOS. No work expected.
10. **Small Linux-isms found by audit** (each a few lines):
    - `getrusage(RUSAGE_THREAD)` in `ThreadLocalHeap.cpp:466,557` —
      `RUSAGE_THREAD` is Linux-only; Darwin → `thread_info(mach_thread_
      self(), THREAD_BASIC_INFO, …)` or compile the profiling counter out.
    - `popen("addr2line …")` in `runtime/src/main.cpp:177` (crash
      symbolization) — addr2line doesn't exist on macOS; use `atos` or
      just skip (diagnostics-only).
    - `/etc/timezone` in `elm-kernel-cpp/src/time/TimeExports.cpp:116` —
      Debian-ism; macOS uses the `/etc/localtime` symlink target (check
      the existing `__APPLE__` branch actually covers zone-name lookup).

### M3 — JIT E2E green (the main verification gate)

11. Build target `test` (JIT E2E) and run
    `cmake --build build --target full`. Expected friction points, in
    order of likelihood:
    - **Apple Silicon W^X**: verified against LLVM 20/21 sources — **no**
      LLVM memory manager (neither RTDyld `SectionMemoryManager` nor
      JITLink) does `MAP_JIT`/`pthread_jit_write_protect_np` for you.
      However, the plain RW→`mprotect`→RX sequence SectionMemoryManager
      uses works on arm64 for ordinary ad-hoc-signed processes (this is
      why clang-repl runs unmodified) — which covers our dev/test case.
      A custom memory manager with MAP_JIT is only needed if we ever ship
      `eco` under Hardened Runtime/notarization; defer to a follow-up.
      Note RTDyld/MCJIT are deprecated upstream (LLVM 20+) in favor of
      ORC+JITLink — not urgent, but the macOS port is the natural moment
      to evaluate migrating `EcoJIT.cpp`.
    - **aarch64 statepoints**: confirmed supported upstream since LLVM 12
      (`Statepoints.html`: "only Aarch64 and X86_64 are supported") and
      production-proven (GraalVM ships statepoint+stackmap binaries on
      darwin-arm64). Three concrete caveats from upstream research:
      (a) the `gc-transition` statepoint flag is **unimplemented** on
      AArch64 (open llvm issue #61264) — verify Eco's RS4GC pipeline
      never emits GC transition bundles; (b) AArch64 stackmaps can emit
      x19 **base-pointer-relative** indirect entries when a frame has
      dynamic/overaligned allocas — the stackmap consumer
      (`StackMap.cpp`) must handle that register, not just fp/sp;
      (c) `__LLVM_STACKMAPS` is unreferenced by code, so ld64
      `-dead_strip` can drop it — mark live or don't dead-strip.
    - `-Wl,--whole-archive` in `test/CMakeLists.txt` is GNU syntax; ld64
      needs `-Wl,-force_load,<lib>` per archive (or
      `-Wl,-all_load`). Gate on `if(APPLE)`.

### M4 — AOT: `eco make` producing Mach-O executables

12. **`EcoNativeDriver.cpp::linkExecutable`** grows a Darwin profile
    alongside the existing glibc/musl branches: invoke `clang` (or `ld64`
    directly) with `-syslibroot $(xcrun --show-sdk-path)`, dynamic
    `-lSystem -lc++`, plus the project/kernel `.a` archives from the
    bundle dir. **Require Xcode Command Line Tools** on user machines —
    this is the standard, reasonable macOS prerequisite (provides ld64 +
    SDK stubs) and removes any need to bundle crt/libc the way Stage C
    does on Linux. Document it; error with a clear message if
    `xcode-select -p` fails.
    - `EcoBootConfig.h` generation in `runtime/src/codegen/CMakeLists.txt`
      gets a Darwin branch emitting SDK-relative config instead of the
      musl/glibc archive lists.
    - Code signing: arm64 Mach-O must be signed; ld64 (and lld's Mach-O
      port) ad-hoc-sign automatically. Verify with `codesign -dv` on a
      test output.
    - Watch for the `.llvm_stackmaps` relocation issue that forced bfd on
      Linux Stage A (`R_X86_64_64` in PIE) — Mach-O relocation model
      differs; test early with a GC-exercising AOT binary.
13. **Bundle layout**: reuse the Stage C `lib/eco-runtime/project/*.a`
    layout but with only the project archives (no crt, no libc.a, no
    bundled linker). CPack: `TGZ` + eventually a notarized `.pkg` or
    Homebrew formula (out of scope for v1; tarball first).

### M5 — Tests + docs

14. `elm-tests` target via the mac elm-test-rs binary; full E2E suite;
    `TEST_FILTER` works as-is (POSIX shell exists).
15. Document setup in `guides/build-macos.md`: CLT, brew deps
    (`cmake ninja node pnpm llvm`), preset usage.

## Dependency mapping: Linux → macOS

The complete Linux dependency list (left column) is verified against the
`eco` link line (`compiler/CMakeLists.txt` Stage 9b), the kernel CMake
files, the Stage C bundle contents, and `compiler/cmake/toolchain.cmake`.
The same list appears in `plans/build-on-windows.md` mapped to Windows.

### Libraries linked into `eco` and/or AOT outputs

| Linux dependency | Role | On macOS |
|---|---|---|
| glibc (dyn, Stage A) / musl `libc.a` (Stage B/C) | libc | **libSystem, dynamic** (only option Apple permits; ABI-stable). No static libc exists or is needed. |
| libstdc++ (dev) / libc++ + libc++abi (release) | C++ runtime | SDK **libc++, dynamic** (Apple system library). |
| compiler-rt builtins (musl static) | low-level intrinsics | Automatic — Apple clang links its own `libclang_rt.osx.a` via the driver; nothing to configure. |
| crt objects (`crt1.o`, `crtbegin/crtend`, bundled in Stage C) | program startup | **Not a thing on Mach-O** — ld64 needs no user-supplied crt objects; drop from the bundle entirely. |
| LLVM + MLIR 21.1.4 static libs (`/opt/llvm-mlir`) | backend + JIT | `brew llvm@21` = **21.1.8 incl. MLIR** (bottle, minutes; patch-skew vs 21.1.4 is API-stable) — or exact 21.1.4 source build if bit-pinning ever matters. brew `llvm` 22.x: avoid (major skew). |
| libcurl (system .so dev / vendored 8.11.0 static release) | HTTP kernel | **System `libcurl.4.dylib`** (SDK `.tbd` stub, present on every macOS; TLS = SecureTransport + system trust store). No vendoring. |
| OpenSSL `libssl` + `libcrypto` | curl TLS backend + one direct `<openssl/sha.h>` use (`Http.cpp:31`) | **Eliminated.** TLS comes with system curl; SHA via a small `eco::sha256` wrapper → CommonCrypto (`CC_SHA256`). Linux impl of the wrapper keeps OpenSSL. |
| zlib (system dev / vendored 1.2.13 release) | curl/libzip dep + AOT `-lz` | **System `libz.dylib`** from the SDK — Apple ships and guarantees it. |
| libzip 1.11.4 (system .so dev / FetchContent-vendored static release) | package zip extraction (read-only) | **Same FetchContent vendoring, unconditionally** — libzip is not in the macOS SDK; static `libzip.a` avoids a brew runtime dep for users. |
| LLVM libunwind (`cmake/LLVMLibunwind.cmake`) | GC stack walk + JIT eh_frame | **System libunwind** — it *is* LLVM libunwind on macOS; headers in the SDK. The cmake module short-circuits to system on Darwin. Nothing bundled. |
| pthread / dl / m / rt (glibc sub-libs) | threads, dlsym, math | All inside **libSystem**; no separate link flags. |
| Node N-API headers | `.node` embed outputs | Same (node-provided headers, cross-platform). |
| rapidcheck | tests only | Same (find_package / FetchContent; builds on mac). |

### Host toolchain

| Linux dependency | On macOS |
|---|---|
| clang/clang++ + lld (bfd for Stage A) | AppleClang (or brew clang) + **ld64** from Xcode CLT — drop `-fuse-ld=lld`; `ld64.lld` only as fallback. |
| Bundled `ld.lld` + crt/libc archives (Stage C, AOT on bare machines) | **Not bundled** — require Xcode CLT on user machines (provides ld64 + SDK stubs); standard macOS prerequisite. |
| CMake ≥3.20 + Ninja | Same — **CMake + Ninja remain the build driver on macOS** (brew install; already preinstalled on GitHub runners). Presets gain a Darwin condition. The few bash helpers (`cmake/glibc_floor.sh` — glibc-only, not invoked on Darwin; `sh -c gunzip` in toolchain.cmake) run fine under macOS's /bin/bash. |
| node + pnpm | Same (brew). |
| elm 0.19.1 / elm-format 0.8.7 / elm-test-rs 3.0.1 Linux prebuilts | Upstream mac prebuilts, **arm64 native available for all three** (asset names verified — see M1.1). |

Net effect on the AOT bundle: `lib/eco-runtime/` on macOS carries **only
the project/kernel archives + `libzip.a`** — no linker, no crt, no libc,
no TLS libs. Outputs link `-lcurl -lz -lc++ -lSystem` dynamically from
the SDK.

## Non-disruption of the Linux build

- **No Linux file paths change.** All Darwin work is additive:
  - New presets only; existing `dev`/`build`/`release` untouched (adding a
    `condition: Linux` to them is the one edit, and it is behavior-neutral
    on Linux).
  - CMake platform logic gated `if(APPLE)` with the existing code kept as
    the `else`/Linux branch verbatim.
  - C++ divergence isolated to: one helper in `EcoBootConfig.cpp`, the
    symbol-walk in `eco_entry.cpp`, stackmap section lookup, and a new
    Darwin branch in `linkExecutable` — each behind `#ifdef __APPLE__`
    with Linux code untouched.
- The docker release pipeline (`docker/static-build.Dockerfile`, Stages
  A–D) is not referenced by any Darwin path and cannot regress.
- Gate: before merging each milestone, run the full Linux
  `cmake --build build --target full` to confirm zero behavioral change.

## Confidence assessment

**Overall: high (~85%) that a fully working macOS eco — arm64-native —
is achievable with the plan above; very high (~90%+) for compiler
bootstrap + JIT tests.** (Raised from the initial ~75–80% after desk
verification, 2026-06: toolchain prebuilts confirmed for arm64 including
elm 0.19.1's `-ARM` asset; AArch64 statepoints confirmed supported since
LLVM 12 and production-proven by GraalVM on darwin-arm64; the W^X question
resolved — plain mprotect RW→RX works for ad-hoc-signed processes, MAP_JIT
only needed under Hardened Runtime; brew-llvm-ships-MLIR confirmed.)

Well-understood, low risk: toolchain URLs, bootstrap (pure Node), mmap heap,
pthreads/signals/process/file kernel code, libunwind (it's the system one),
executable-path/dlsym substitutions, dynamic AOT linking via CLT.

~~Risk 1 (AArch64 stackmap details) and risk 2 (ld64 stackmaps
handling)~~ — **RESOLVED by experiment E-M1** (run 2026-06-12 on
`macos-15` arm64, all six checks PASS in a 45-second job; see the E-M1
results below). Confirmed: end-to-end statepoint root recovery works on
arm64 macOS; x19 base-pointer entries appear exactly as predicted (the
`StackMap.cpp` consumer must handle DWARF reg 19); dyld rebases the
recorded function addresses (no slide adjustment needed — the Linux
ELF-PIE stackmap relocation problem has no runtime Mach-O analogue); ld64
links and ad-hoc-signs (`linker-signed`) automatically. One actionable
finding: **`-dead_strip` removes `__LLVM_STACKMAPS`** — the AOT link
driver must not pass it (or must add a keep-alive). The `gc-transition`
flag question was separately closed by grep: Eco's codegen emits no
invokes, landingpads, or gc-transition bundles.

Remaining risks:
1. LLVM 21.1.4 source build on the mac is slow but proven (same recipe as
   the Alpine builder); brew `llvm@21` 21.1.8 is the verified quick path
   (E-M1 used it: 26-second bottle install).

(The earlier "12 GB node heap vs 7 GB runner" concern is withdrawn: the
`NODE_OPTIONS=--max-old-space-size=12000` in `compiler/CMakeLists.txt`
applies only to the Stage 9-2 self-compile — stages 1–5 run with the
default heap — and per the maintainer the 12 GB figure is stale; the
bootstrap fits in ~4 GB since the front-end memory fixes. Lowering the
Linux setting is a separate cleanup once the actual peak is measured.)

With E-M1 green, overall confidence rises to **~90%**; what's left is
integration work (M2 seams, link driver), not platform unknowns.

## GitHub-runner experiments (no Apple hardware required)

Runner facts (verified 2026-06): standard hosted runners are **free with
no minute metering on public repos** (private repos burn macOS minutes at
**10×** — effectively requires a public repo or a paid plan).
`macos-latest` = `macos-15`, **arm64** (M1-class, 3 vCPU / 7 GB RAM /
14 GB SSD); Intel needs the explicit `macos-15-intel` label. Limits: 6 h
per job, 10 GB actions/cache. Preinstalled: Xcode 16.4 + CLT, Homebrew,
CMake, Ninja, Node 22.

Repo logistics: eco already has a public GitHub repo —
**github.com/eco-lang/eco-compiler** — so all experiments run there for
free. Branch strategy: workflows under `.github/workflows/` do **not**
need to be on master — `on: push`-triggered workflows run the version in
the pushed commit on any branch, so develop each experiment on a
`ci/**` branch with `on: push, branches: ['ci/**']`. Only
`workflow_dispatch` (manual-run button) requires the file to exist on the
default branch to be registered (it can then run against any branch ref);
merge a thin dispatch-triggered version to master once an experiment is
worth keeping for re-runs.

### E-M1 — Statepoint/stackmap smoke on arm64 (no eco code) — ✅ DONE, ALL PASS
**Run 2026-06-12** (`experiments/mac-statepoint-smoke/`, branch
`ci/mac-build-experiment`, job time ~45 s). Results:
- Root recovered at the safepoint in both variants: plain frame =
  `Indirect [sp+8]`; dynamic-alloca frame = `Indirect [x19+24]` —
  **x19 base-pointer entries confirmed**, `StackMap.cpp` must handle
  DWARF reg 19.
- Function addresses matched **raw** — dyld rebases the section; no
  slide adjustment needed.
- **`-dead_strip` removes `__LLVM_STACKMAPS`** — link driver must avoid
  it or keep the section alive.
- ld64 output is automatically **ad-hoc linker-signed** — arm64 signing
  needs no action.
- `brew install llvm@21` (21.1.8 + MLIR) poured in 26 s. Caveat noted:
  brew warns llvm@21 conflicts-on-link with the preinstalled llvm@18 —
  irrelevant since we use absolute keg paths, never `brew link`.

Original spec (for reference):
- `brew install llvm@21` (bottle).
- A ~50-line `.ll` safepoint-rewritten via
  `opt -passes=rewrite-statepoints-for-gc`, then
  `llc -mtriple=arm64-apple-darwin` → `.o`, linked with system clang/ld64
  into a C++ harness that locates `__LLVM_STACKMAPS,__llvm_stackmaps` via
  `getsectiondata`, parses the StackMap v3 records, and walks the stack
  with system libunwind at a poll, matching return addresses to records.
- Variants in one job: (a) plain frame; (b) overaligned/dynamic alloca →
  expect **x19 base-pointer-relative** entries; (c) link with
  `-dead_strip` → does the section survive, and what keeps it alive;
  (d) `codesign -dv` — ad-hoc signature present?
- Pass criterion: roots identified at the safepoint in all variants.

### E-M2 — eco configure + bootstrap stages 1–5 — ✅ DONE, ALL GREEN
**Run 2026-06-12** on `macos-15` arm64: full chain in **under 4 minutes**
(configure 4.4 s; stages 1–4b ~95 s incl. the JS fixed-point check
passing; stage 5 ~2 min → `eco-compiler.mlir`, 12 MB, 239 modules). The
mac arm64 elm/elm-format/elm-test-rs prebuilts fetched + SHA-verified;
gtime found; AppleClang 17 configured the (empty) C/C++ side.
One fix was needed: stage 5 OOM'd at node's **RAM-scaled default heap**
(~2 GB on the 7 GB runner vs ~4 GB on big dev machines) — now pinned
explicitly with `--max-old-space-size=4096` in `compiler/CMakeLists.txt`,
confirming the bootstrap fits in 4 GB. The front-end is fully proven on
macOS; everything remaining is the native backend/runtime port (M2–M4).

Implementation notes (as built):
Implemented on `ci/mac-build-experiment` (workflow
`.github/workflows/mac-bootstrap.yml`) as a **front-end-only** experiment
— no LLVM needed at all, because stages 1–5 are pure Node/Elm:
- `compiler/cmake/toolchain.cmake`: per-platform URL/SHA table (Linux
  x86_64 + mac arm64 + mac x86_64; mac SHAs computed from upstream
  2026-06-12).
- `compiler/CMakeLists.txt`: platform gate admits Darwin; GNU time →
  `gtime` (brew gnu-time) on Darwin; stages 6–9 gated behind
  `NOT ECO_FRONTEND_ONLY` (their `$<TARGET_FILE:eco-boot-native>`
  genexes are configure errors without the backend).
- Top-level `CMakeLists.txt`: new `ECO_FRONTEND_ONLY` option skipping
  LLVMLibunwind, runtime, kernels, and tests; `mac-frontend` preset
  (Darwin-conditioned) in CMakePresets.json.
- Workflow: brew pnpm + gnu-time → `cmake --preset mac-frontend` →
  `--target eco-boot-verify` (stages 1–4b incl. JS fixed point) →
  `--target eco-compiler-mlir` (stage 5) → timing logs as artifacts.
- **Linux non-disruption verified locally**: fresh-dir configures of both
  `ECO_FRONTEND_ONLY=ON` (frontend targets present, backend absent) and
  the default path (all stage-6–9 targets present) pass on Linux.
- Node heap: not a concern — stages 1–5 use the default heap; the 12 GB
  `NODE_OPTIONS` applies only to Stage 9-2 and is stale (bootstrap now
  fits ~4 GB per the maintainer).

### E-M3 — Runtime + JIT E2E — in progress (seams implemented, CI iterating)
M2 seams implemented on `ci/mac-build-experiment` (2026-06-12):
- `runtime/src/platform/PlatformPaths.hpp` (new, header-only):
  `currentExecutablePath()/currentExecutableDir()` —
  `_NSGetExecutablePath`+realpath on Darwin, readlink(/proc/self/exe) on
  Linux. All five former readlink sites rewired (`main.cpp`,
  `EcoBootConfig.cpp`, `eco-kernel-cpp/Runtime.cpp`; `eco_entry`/`eco_embed`
  via the stackmap helper below).
- `runtime/src/platform/StackMapSection.hpp` (new, header-only):
  `findStackMapSection(addr)` — unifies the two near-identical ELF
  phdr/section walks from `eco_entry.cpp` and `eco_embed.cpp`; Darwin impl
  is dladdr + `getsectiondata` (the E-M1-proven approach).
- `RUSAGE_THREAD` profiling counters guarded (`#if defined(RUSAGE_THREAD)`,
  read 0 on Darwin); `MAP_NORESERVE` fallback-defined to 0 in
  `Allocator.cpp`; addr2line crash symbolization degrades gracefully (no
  code change needed beyond the exe-path helper).
- `LLVMLibunwind.cmake`: Darwin short-circuit to an empty interface target
  (system libunwind IS LLVM libunwind). `test/CMakeLists.txt`:
  `--whole-archive` → per-archive `-force_load` on APPLE.
  `-rdynamic` → `ENABLE_EXPORTS` property on APPLE.
- `mac-build` preset (full configure, `CMAKE_PREFIX_PATH` →
  `/opt/homebrew/opt/llvm@21`, AppleClang, ld64) +
  `.github/workflows/mac-runtime.yml` (deps incl. rapidcheck
  brew-or-source, ccache via actions/cache, `-k 20` error batching,
  runs `build/test/test`).
- **Linux non-disruption verified**: fresh configure + build of
  `EcoEntryStatic EcoEmbedStatic EcoKernel_Runtime ecor` passes with all
  edits.
Remaining: iterate CI compile errors to green, then the full E2E suite.

### E-M4 — AOT: `eco make` → Mach-O, run, GC-stress
After M4. Verifies ld64 + `__llvm_stackmaps` at AOT link (confidence
risk 2) and the CLT link driver; include one GC-heavy program and
`codesign -dv` on the output.

Workflow mechanics: one workflow per experiment, `on: push` on its
`ci/**` branch while iterating; promote to a `workflow_dispatch` stub on
master once green. Cache brew downloads, ccache, `~/.eco`;
always `upload-artifact` the logs. Later: a 3-OS matrix where the Linux
job is the non-regression guard.

## Suggested order

M1 → M2 → M3 → M4 → M5, arm64-native throughout (the original
"x86_64/Rosetta first" hedge is no longer warranted now that arm64
statepoints and toolchain prebuilts are confirmed; keep Rosetta only as a
fallback if risk 1 above bites). Do macOS **before** Windows: it forces the platform seams (exe path, section
discovery, link driver profiles) at minimal cost, and Windows then fills in
the same seams rather than inventing them.
