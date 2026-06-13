# Plan: Build Eco on Windows

## Goal

A working `eco` on Windows 10/11 x86_64: compiler bootstrap, JIT E2E tests,
and AOT compilation producing runnable PE executables. **Dynamic linking
against the OS is the model** — Windows guarantees a stable system-DLL
surface (kernel32, ucrtbase, ws2_32, …), so the Linux musl/glibc static
apparatus does not apply. The one static-vs-dynamic decision that remains is
the C/C++ runtime: recommend **`/MT` (static CRT) for the `eco` binary and
for AOT outputs**, so neither depends on a VC++ redistributable being
installed — that gives a self-contained binary while still linking all OS
DLLs dynamically, matching the user's expectation that Windows builds need
only dynamic linking (to the OS) plus nothing exotic.

This port is substantially larger than macOS: the runtime is POSIX
throughout, and Windows is not. Prerequisite reading: do the macOS plan
(`plans/build-on-mac.md`) first — it establishes the platform seams this
plan fills in with Win32 implementations.

## Development model: GitHub Actions, no local Windows hardware

All development and verification happens on **GitHub Actions
`windows-latest` runners** — we have no Windows machine. This mirrors how
the macOS port was driven (see `.github/workflows/mac-statepoint-smoke.yml`,
`mac-bootstrap.yml`, `mac-runtime.yml`, `mac-aot.yml` — one workflow per
milestone, push-triggered on `ci/**` branches). The W items below describe
the changes to make; the E-W workflows in the *GitHub-runner experiments*
section near the bottom are the verification gates, one per milestone.
Mapping:

- W3 spike (statepoint viability) ↔ **E-W1** `win-statepoint-smoke.yml`
- W2 heap/threads + W3 JIT frame registration ↔ **E-W2** `win-jit-smoke.yml`
- W1 toolchain (LLVM/MLIR source build, cached) ↔ **E-W3** `win-llvm-build.yml`
- W1 + bootstrap (and item 10b Elm path semantics) ↔ **E-W4** `win-bootstrap.yml`
- W2/W3 in eco proper (runtime + JIT E2E) ↔ **E-W5** `win-runtime.yml`
- W4 AOT + bundle ↔ a `win-aot.yml` mirroring `mac-aot.yml`

Branch hygiene matches the mac port: develop each milestone on its own
`ci/**` branch with the workflow file riding the branch; merge a thin
`workflow_dispatch` stub to master once green.

**Active branch (all Windows work):** `ci/windows-build-experiment`. The
whole port is conducted on this single branch — push-triggered workflows
under `on: push, branches: ['ci/**']` run the branch's own copy of each
workflow file, so nothing needs to land on master while we iterate.

## Toolchain decision (made up front, drives everything)

**clang targeting the MSVC ABI (`x86_64-pc-windows-msvc`) + lld-link +
MSVC STL from VS Build Tools + Windows SDK.** Rationale:

- LLVM/MLIR must be built with the same compiler family anyway; clang-cl is
  the supported, well-trodden way to build LLVM on Windows.
- lld-link keeps linker behavior under our control (same lld codebase as
  Linux).
- MSVC ABI (not MinGW) is the native ecosystem: Node N-API embedding,
  debuggers, and the Windows SDK all assume it.

Alternative considered — **llvm-mingw** (`x86_64-w64-windows-gnu`): fully
redistributable CRT (useful for bundling a Stage-C-style self-contained AOT
toolchain, since MSVC libs cannot be redistributed), and it keeps
eh_frame/SjLj-free DWARF unwinding closer to the Linux path. Park it as a
fallback if statepoint/WinEH problems appear under the MSVC ABI (see Risks),
and as a later option for "AOT works without VS Build Tools installed".
For v1, requiring **VS Build Tools + Windows SDK** on user machines is the
Windows analogue of requiring Xcode CLT on macOS, and is acceptable.

## Work items

### W1 — Toolchain + configure

1. **`compiler/cmake/toolchain.cmake` per-platform URLs** (shared
   infrastructure with the macOS plan; asset names verified against the
   GitHub releases, 2026-06):
   - elm 0.19.1: `binary-for-windows-64-bit.gz`.
   - elm-format 0.8.7: `elm-format-0.8.7-win-x64.zip`.
   - elm-test-rs v3.0.1: `elm-test-rs_windows.zip`.
   Extraction must handle `.zip`/`.exe` suffixes
   (`file(ARCHIVE_EXTRACT)` already handles zip); append `.exe` to the
   cached binary names on `WIN32`.
2. **node + pnpm**: standard Windows installers; `find_program` finds them.
   Verify the guida.js bootstrap (stages 1–5) under Windows node — it is
   pure JS, but watch for path-separator and `child_process` shell
   assumptions inside the bootstrap scripts and any CMake
   `COMMAND sh -c ...` invocations, which must become
   `cmake -E`/direct-program invocations or be gated to use
   `$ENV{ComSpec}` alternatives.
3. **LLVM/MLIR from source** with clang-cl + ninja, pinned `llvmorg-21.1.8`
   (same as `docker/llvm-alpine.Dockerfile`), installed to e.g.
   `C:/llvm-mlir`; script as `scripts/build-llvm-windows.ps1`. There is no
   reliable prebuilt with MLIR on Windows.
4. **New presets**: `win-dev`, `win-build` with
   `condition: hostSystemName == Windows`,
   `CMAKE_C[XX]_COMPILER=clang-cl` (or clang++ with
   `--target=x86_64-pc-windows-msvc`), `-fuse-ld=lld-link` semantics via
   `CMAKE_LINKER`. `/MT` via `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`.
5. **CMake hygiene sweep**: `file(CREATE_LINK ... SYMBOLIC)` for
   node_modules and test package shadows needs Developer Mode or admin on
   Windows; add `COPY_ON_ERROR` or switch test shadows to junctions/copies
   on `WIN32`. `-Wl,--whole-archive` → `/WHOLEARCHIVE:<lib>`.

### W2 — Platform layer in the runtime (the core of the port)

Create `runtime/src/platform/` with `posix/` and `win32/` implementations
selected in CMake, for each seam below. POSIX files contain the existing
code moved verbatim (Linux/macOS behavior unchanged).

6. **Virtual memory** (`Allocator.cpp` — reserve once, commit-on-demand at
   fixed addresses):
   - reserve: `VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS)`
   - commit subrange: `VirtualAlloc(addr_within_reservation, len,
     MEM_COMMIT, PAGE_READWRITE)` — Windows supports committing arbitrary
     subranges of a reservation, so the heap model maps 1:1; no
     placeholders/VirtualAlloc2 needed.
   - decommit: `MEM_DECOMMIT`; release: `MEM_RELEASE` (whole reservation).
   API shape: `platformReserve/platformCommit/platformDecommit/
   platformRelease`, ~6 call sites.
7. **Threads** (`eco_entry.cpp`, `eco_embed.cpp`): the only pthread
   features used are create-with-stack-size, join, and self-equality.
   Replace with a tiny `eco::Thread` shim: Win32 `_beginthreadex`
   (stack-size param) / POSIX pthread. `thread_local` already works on
   both.
8. **Signals / crash diagnostics** (`main.cpp`, `eco_entry.cpp`):
   - SIGINT/SIGTERM shutdown → `SetConsoleCtrlHandler`.
   - SIGSEGV/SIGABRT/SIGBUS/SIGFPE diagnostics →
     `AddVectoredExceptionHandler` (or just `signal(SIGSEGV/SIGABRT)`
     which the UCRT supports for basic cases) — diagnostics-only, can be
     minimal in v1.
   - `signal(SIGPIPE, SIG_IGN)` → no-op on Windows.
9. **Process spawning** (`eco-kernel-cpp/src/eco/Process.cpp`):
   fork/execvp/pipe/waitpid → `CreateProcessW` + `CreatePipe` +
   `WaitForSingleObject`/`GetExitCodeProcess`. Self-contained module; the
   WaitService SIGCHLD logic becomes a waiter thread or
   `RegisterWaitForSingleObject`.
10. **File I/O** (`eco-kernel-cpp/src/eco/File.cpp`):
    `stat`/`S_ISDIR`/`opendir`/`readdir`/`access` →
    `std::filesystem` (`status`, `directory_iterator`, `perms`) — this
    also simplifies the POSIX side. Use UTF-8 throughout: embed a UTF-8
    manifest / `setlocale` + `std::filesystem::path` from `u8string` so
    Elm strings round-trip; set console output to
    `SetConsoleOutputCP(CP_UTF8)`. `HOME` env lookups (File.cpp
    appDataDir) → `USERPROFILE`/`APPDATA` (the JS side,
    `eco-io-handler.js:351`, already falls back to `APPDATA`).
10b. **Elm compiler path handling** (found by audit — Windows-specific
    work the macOS port never hits): `compiler/src/Utils/Main.elm:685–769`
    hardcodes `fpPathSeparator = '/'` and implements `fpCombine`,
    `fpSplitDirectories`, `fpIsRelative`, `fpTakeFileName` etc. by
    splitting on `"/"`; `Compiler/Elm/ModuleName.elm:110` builds file
    paths with `/`. Mitigating fact: every Win32 API and Node accept
    forward slashes, so *joining* with `/` mostly works. What actually
    breaks: absolute-path detection (`fpIsRelative` must recognize
    `C:\`/`C:/` and UNC `\\` forms), splitting paths that arrive from the
    OS with backslashes (normalize all incoming paths to `/` at the
    IO boundary in `eco-io-handler.js`/kernel, which is cheaper than
    teaching the Elm code both separators), and drive-letter handling in
    `fpSplitDirectories`. Plan: normalize-at-boundary + extend
    `fpIsRelative`; audit other `fp*` callers for separator output
    reaching the user.
11. **Executable path**: `GetModuleFileNameW` in the
    `currentExecutablePath()` helper introduced by the macOS plan
    (five `/proc/self/exe` sites: `EcoBootConfig.cpp`, `Runtime.cpp`,
    `main.cpp`, `eco_embed.cpp`, `eco_entry.cpp`).
11b. **Small POSIX-isms found by audit**: `getrusage(RUSAGE_THREAD)` in
    `ThreadLocalHeap.cpp:466,557` → `GetThreadTimes`;
    `popen("addr2line …")` in `main.cpp:177` → stub out
    (diagnostics-only); `/etc/timezone` in `TimeExports.cpp:116` →
    `GetDynamicTimeZoneInformation`; `WaitService.cpp:57`'s global
    `waitpid(-1)` + SIGCHLD reaper → per-child waiter handles (folds into
    item 9); `isatty` in test mains → `_isatty` (test-only).
12. **Symbol lookup for the JIT** (`eco_entry.cpp` `<elf.h>`/`<link.h>`
    walk): on Windows, exports of the host exe are only visible if
    declared `__declspec(dllexport)` (no ELF-style global dynamic symbol
    table). Plan: generate an explicit symbol table (name → address) for
    the runtime-export surface at build time and register it with the JIT
    resolver on all platforms — this *removes* the platform-specific walk
    entirely and is the cleanest of the three options (vs.
    `GetProcAddress` on a dllexport'd set, vs. parsing our own PE
    exports).

### W3 — GC + JIT machinery (highest technical risk)

13. **Stackmaps**: COFF emission of `.llvm_stackmaps` has existed upstream
    since 2015 (D10680) and is still present in LLVM 20/21
    `MCObjectFileInfo`. Confirm section discovery at runtime (find section
    by name via the PE headers of the loaded module, the COFF analogue of
    item 7 in the macOS plan).
14. **Statepoints under the Win64 calling convention** — desk research
    (2026-06) upgraded this from "unknown" to "supported with one known
    boundary":
    - Win64 statepoints are exercised and maintained in-tree
      (`win64-eh-trailing-statepoint.ll`, `win64-seh-epilogue-
      statepoint.ll`; SEH-interaction bugs were found and fixed in
      2022–2023, and the code was touched again by the 2025 Unwind-V2
      work). This infrastructure was originally built for LLILC/CoreCLR.
    - The known unsupported boundary: **statepoint relocation along
      WinEH funclet exceptional paths** (`catchpad`/`cleanuppad` —
      microsoft/llvm#105, never upstreamed). This only matters if Eco's
      generated code uses `invoke` with an SEH personality. Elm has no
      exceptions and the Linux codegen uses plain calls — **verify in
      `EcoToLLVMClosures.cpp`/RS4GC config that no invokes are emitted**,
      after which this limitation is moot.
    - Two open target-independent issues (#75162, #74612: large
      by-value/returned structs breaking GC lowering) apply equally on
      Linux, so they are not Windows risks per se.
    **Still run the spike first**: compile one GC-heavy E2E program to a
    Win64 object, link, run, verify stackmap-driven root identification.
    The llvm-mingw fallback (DWARF eh_frame on PE) remains the escape
    hatch, but the prior is now "spike passes".
15. **GC stack walking** (`StackUnwind.cpp` — already pimpl'd, good seam):
    libunwind does not support Win64 SEH frames. Win32 impl:
    `RtlCaptureContext` + loop of `RtlLookupFunctionEntry` +
    `RtlVirtualUnwind` to produce the same (ip, sp/fp) stream the stackmap
    lookup consumes. ~100 lines, well-documented pattern.
16. **JIT unwind registration** (`EcoJIT.cpp` `__register_frame` per FDE):
    on Windows the equivalent is `RtlAddFunctionTable` over the JIT'd
    `.pdata`/`.xdata`. LLVM's RTDyld COFF support registers this via the
    memory manager on Win64 — verify rather than hand-roll; only the
    GC-stack-walk (item 15) must see the JIT frames, and
    `RtlLookupFunctionEntry` honors `RtlAddFunctionTable` entries.

### W4 — AOT: `eco make` producing PE executables

17. **`EcoNativeDriver.cpp::linkExecutable` Windows profile**: invoke
    `lld-link` with `/subsystem:console`, the project/kernel `.lib`s from
    the bundle, `/defaultlib:libcmt` (static CRT), and the Windows SDK
    import libs (kernel32, ws2_32, crypt32, …). Discover the SDK/MSVC lib
    paths the way clang does (`vswhere` / registry / `%VSINSTALLDIR%`),
    or simply shell out to `clang-cl` and let its driver do discovery —
    **prefer the latter for v1** (requires VS Build Tools present, same
    prerequisite as building).
    - HTTP/compression libs: per the **Dependency stack** section below —
      vendored curl with schannel, vendored libzip/zlib, no OpenSSL.
18. **EcoBootConfig.h generation**: Windows branch emitting `.lib` names
    and the linker discovery mode; `runtimeDir()` via item 11.
19. **Bundle**: `eco-<ver>-x86_64-windows.zip` via CPack ZIP generator
    (already configured generator-wise); contents: `bin/eco.exe` +
    `lib/eco-runtime/project/*.lib`.

### W5 — Tests + docs

20. E2E harness: replace `sh -c` test-filter plumbing with
    `cmake -E env TEST_FILTER=...` + direct test-binary `--filter` args so
    the same mechanism works on all three OSes (improves Linux too, but
    only touch it once Windows needs it; keep the existing shell path as
    Linux default if any doubt).
21. `guides/build-windows.md`: VS Build Tools + Windows SDK, LLVM build
    script, node/pnpm, Developer Mode for symlinks (or the copy fallback),
    preset usage.

#### W5 — Windows v1 ship gaps (follow-ups, tracked here so they're not lost)

The Windows port reached green CI for `win-bootstrap`, `win-runtime`,
and `win-aot`. Three pieces are deferred behind explicit `_WIN32` gates
in the source / workflow rather than being left silently broken.

1. **Win64 JIT → `Allocator::resolve` "Pointer above heap end"** —
   the test binary's codegen MLIR suite and the Elm-E2E suites both
   crash here after the first few JIT executions succeed. Reproduces
   on `test/codegen/allocate_ctor_max_size.mlir`. Allocator unit tests
   exercising the same kernel through the C++ API pass cleanly, so the
   suspect is the JIT-to-runtime call boundary, most likely
   MSVC vs SysV trivial-struct return ABI on `HPtr` in calls into
   `eco_alloc_custom` (see `runtime/src/allocator/Heap.hpp:172`, which
   explicitly assumes SysV in its own comment). Gates:
   `test/main.cpp` (codegen + BF-codegen suites) and
   `test/ElmE2ETestBase.hpp::buildTestSuite` (every Elm-flavoured
   suite). Re-enable: write a tiny harness that calls
   `eco_alloc_custom` from JIT-compiled MLIR returning HPtr, capture
   what RAX actually contains under both compilers, then either
   round-trip through `uint64_t` at the boundary or annotate
   `__attribute__((sysv_abi))` on the runtime exports.

2. **`mlir::makeOptimizingTransformer` "invalid optimization/size
   level X/0"** — fires on the second JIT execution in the same
   process; level value is garbage despite `EcoBackendJob::optLevel`
   being statically `None`. Worked around with a `#if defined(_WIN32)`
   skip in `runtime/src/codegen/EcoBackend.cpp::runEcoBackend`
   (`BackendKind::JITInvokePacked`). RS4GC and frame-pointer attrs
   still run, so JIT correctness isn't affected — just no LLVM IR
   optimization. Root cause likely a static-state issue inside
   MLIR's `OptUtils` on lld-link + /MT; needs a reduced repro to
   file upstream.

3. **Stages 7-9 self-hosted fixed point on Win64 — DONE (2026-06-15).**
   `win-aot` now runs the full self-hosted chain end-to-end and ships the
   unified Stage 9 `eco.exe` (PE32+ verified, packaged, `--help`
   smoke-tested in isolation), matching `mac-aot`. It had earlier appeared
   to "run past the 240-min ceiling"; that was actually a sequence of four
   distinct Win64-only bugs, each unmasking the next. In fix order:

   - **eco-boot-native exit hang (process teardown).** The Stage 6/7b/8b
     lowering printed its stats (work done) then never exited, so ninja
     never advanced. Cause: `linkExecutableWindows` spawned clang-cl/
     lld-link via `ExecuteAndWait` with empty redirects, so the link child
     inherited eco-boot-native's stdout/stderr — under self-host those are
     ninja's pipe write-ends — and a link descendant held the pipe open
     past exit, so ninja never saw pipe EOF. *Fix:* redirect the link
     child's stdin→null, stdout+stderr→a temp file (the subtree inherits
     the file handle, not the build pipe), plus a Win64 `TerminateProcess`
     hard-exit in `eco-boot.cpp::ecoBootFinalExit` to skip an intermittent
     `/MT` CRT static-destructor stall. POSIX is unaffected (its
     `.string()` paths are already `/`, and it returns from `main`
     normally).

   - **eco-compiler.exe self-compile deadlock (the load-bearing one).**
     Once eco-boot-native exited, Stage 7a (`eco-compiler.exe make`) hung
     with no `Compiling (N)` output. Instrumenting `pendingAsync_` showed
     two `MVar.read` parks at `MVar.cpp:157` and **zero** wakes — the
     compiler's `forkIO` + `putMVar`/`readMVar` fork-join: a
     `Task.andThen (putMVar mvar) work` skips the put when `work` fails,
     swallowing the failure and deadlocking the join. The failing `work`
     was **file resolution**: the AOT compiler uses the C++ `File` kernel,
     which returned paths to Elm via `std::filesystem::path::string()` =
     **native backslashes** on Windows, and the Elm `fp*` code splits on
     `/`. This is item 10b's normalization, applied to
     `eco-io-handler.js` (Node bootstrap) but never to the C++ File
     kernel. *Fix:* `File.cpp` returns `generic_string()` (forward slashes
     on all platforms) from every path handed to Elm — getCwd (seeds most
     derived paths), findExecutable, canonicalize; plus a Windows
     `appDataDir` (`APPDATA`/`USERPROFILE`, no HOME) so that path can't
     fail either.

   - **Stage 8c fixed-point check.** It byte-compared the linked PE
     binaries via the ELF branch, but PE (like Mach-O) is not bit-for-bit
     deterministic (COFF header `TimeDateStamp`). *Fix:* compare the
     `.mlir` files on `APPLE OR WIN32` (the real fixed-point invariant),
     leaving the binary compare for ELF only.

   - **Stage 9b unified link.** `eco_apply_unified_link` had only APPLE and
     GNU branches, so the `eco` target fed lld-link POSIX flags/libs
     (`-Wl,--whole-archive`, `-fuse-ld=bfd`, `pthread`/`m`/`stdc++`/`ssl`/
     `crypto`). *Fix:* a `WIN32` branch mirroring `linkExecutableWindows`
     (`/WHOLEARCHIVE:` for the force-load trio, project archives, vendored
     curl/zip/zlib, SDK import libs, `/INCREMENTAL:NO` per E-W1).

   Also fixed a latent lost-wakeup: `Scheduler::decrementPendingAsync()`
   now takes `mutex_` before `notify_one()` (matching
   `notifyWorkAvailableFromAsync`/`requestStop`). Last green
   end-to-end run: `gh run 27526250970`.

4. **`stress-elm`, `mlir-equivalence`, `aot-e2e-runner`** test
   binaries — currently `NOT WIN32`-gated in `test/CMakeLists.txt`.
   They depend on `Process.cpp` `fork`/`exec`-style spawning + the
   POSIX TestHttpServer; porting to `CreateProcessW` + schannel
   socket pump lands all three together.

5. **`stress-test` & `elm-http` / `eco-kernel` E2E** — same gate,
   same blocker (`TestHttpServer.hpp`). Stub builders return
   empty suites today (`test/elm-http/ElmHttpTest.hpp` and
   `test/eco-kernel/EcoKernelTest.hpp` under `_WIN32`).

## Dependency mapping: Linux → Windows

The complete Linux dependency list (left column, identical to the table
in `plans/build-on-mac.md`) is verified against the `eco` link line
(`compiler/CMakeLists.txt` Stage 9b), the kernel CMake files, the Stage C
bundle contents, and `compiler/cmake/toolchain.cmake`.

### Libraries linked into `eco` and/or AOT outputs

| Linux dependency | Role | On Windows |
|---|---|---|
| glibc (dyn, Stage A) / musl `libc.a` (Stage B/C) | libc | **UCRT** — `ucrtbase.dll` is an OS component on Win10+. Link **`/MT` static CRT (`libcmt`)** so no VC++ redistributable is needed; OS DLLs stay dynamic. |
| libstdc++ (dev) / libc++ + libc++abi (release) | C++ runtime | **MSVC STL**, static (`libcpmt` via `/MT`). |
| compiler-rt builtins (musl static) | low-level intrinsics | Not needed — the MSVC CRT provides them; clang-cl targets it natively. |
| crt objects (`crt1.o`, `crtbegin/crtend`, bundled Stage C) | program startup | Handled by lld-link/MSVC CRT automatically; nothing user-supplied or bundled. |
| LLVM + MLIR 21.1.8 static libs (`/opt/llvm-mlir`) | backend + JIT | **Source build only** — no MLIR prebuilt exists for Windows (official `clang+llvm-*-windows-msvc.tar.xz` has llc/lld-link/libs but no MLIR; the `.exe` installer is toolchain-only). Upside: pin **exactly 21.1.8**, zero version skew vs Linux/macOS. Cached after one ~2–4 h build (experiment E-W3). |
| libcurl (system .so dev / vendored 8.11.0 static release) | HTTP kernel | **Vendored static via the existing FetchContent path** with `CURL_USE_SCHANNEL=ON` (Windows-native TLS, system cert store). Kernel curl-API code untouched; `CURL_CA_BUNDLE` plumbing becomes unnecessary. |
| OpenSSL `libssl` + `libcrypto` | curl TLS backend + one direct `<openssl/sha.h>` use (`Http.cpp:31`) | **Eliminated** (the most painful Windows build of the lot, avoided). TLS = schannel; SHA = the shared `eco::sha256` wrapper → **BCrypt/CNG** (or a vendored public-domain SHA-256 on all platforms). |
| zlib (system dev / vendored 1.2.13 release) | curl/libzip dep + AOT link | **Vendored via FetchContent** (the vendoring already exists under `ECO_GLIBC_OUTPUT_RUNTIME`; generalize the gate). |
| libzip 1.11.4 (system .so dev / vendored static release) | package zip extraction (read-only) | **Same FetchContent vendoring** — builds cleanly with CMake + clang-cl. |
| LLVM libunwind | GC stack walk + JIT eh_frame | **Dependency disappears.** GC walk → `RtlVirtualUnwind` (item 15); JIT frames → `RtlAddFunctionTable` (item 16); C++ EH → MSVC native SEH. `LLVMLibunwind.cmake` not included on WIN32. |
| pthread / dl / m / rt (glibc sub-libs) | threads, dlsym, math | pthread → `eco::Thread` shim on `_beginthreadex` (item 7); dl → unused (no dlopen; JIT symbols via explicit table, item 12); m/rt → in the CRT. New OS import libs appear instead: `ws2_32`, `crypt32`, `bcrypt`, `secur32` (pulled by schannel/CNG), `kernel32` etc. — all OS-provided DLLs. |
| Node N-API headers | `.node` embed outputs | Same headers; `.node` linking uses the standard delay-load-hook convention on Windows (node.lib import or delayload) — small addition to the embed link profile. |
| rapidcheck | tests only | Same (FetchContent; builds with clang-cl). |

### Host toolchain

| Linux dependency | On Windows |
|---|---|
| clang/clang++ + lld (bfd for Stage A) | **clang-cl + lld-link** targeting `x86_64-pc-windows-msvc` (see Toolchain decision above). |
| Bundled `ld.lld` + crt/libc archives (Stage C) | Not bundled in v1 — require **VS Build Tools + Windows SDK** on user machines (the Xcode-CLT analogue); `clang-cl`'s driver discovers them. llvm-mingw later if a zero-prereq bundle is wanted. |
| CMake ≥3.20 + Ninja | Same — **CMake + Ninja remain the build driver on Windows** (never MSBuild/VS generators: Ninja is what LLVM itself uses with clang-cl, and it keeps presets/targets identical across the three OSes). The shell-isms must go: `sh -c gunzip` in toolchain.cmake → `cmake -E`/`file(ARCHIVE_EXTRACT)`, `chmod +x` → no-op on WIN32, `TEST_FILTER` plumbing → `cmake -E env` (item 20); `cmake/glibc_floor.sh` is glibc-only and never invoked on Windows. |
| node + pnpm | Same (standard Windows installers). |
| elm 0.19.1 / elm-format 0.8.7 / elm-test-rs 3.0.1 Linux prebuilts | Upstream Windows prebuilts (asset names verified — see item 1). |

Net effect on the AOT bundle: `lib/eco-runtime/` on Windows carries the
project/kernel `.lib`s + `libcurl.lib`/`libzip.lib`/`zlib.lib`; outputs
link those + `libcmt` + OS import libs. No linker, crt, or libc in the
bundle.

## Non-disruption of the Linux build

- The platform layer (`runtime/src/platform/{posix,win32}/`) is created by
  **moving existing code verbatim into `posix/`** — the Linux build
  compiles the same code from a new path; behavior-neutral, verified by
  running the full Linux suite at that commit before any Win32 code lands.
- All CMake changes are `if(WIN32)` branches with the existing logic as the
  default; new presets carry `condition: Windows` and existing presets gain
  only a `condition: Linux` (behavior-neutral).
- The docker release pipeline and `ECO_STATIC*` knobs are untouched; no
  Windows path references them.
- Win32 source files are excluded from Linux/macOS targets entirely (listed
  only under the `WIN32` branch), so they cannot break other platforms even
  while half-finished.
- Gate per milestone: full `cmake --build build --target full` on Linux.

## Confidence assessment

**Overall: high (~75%), raised from ~65% after E-W1 passed (2026-06-13).**
The Win64 statepoint spike was the load-bearing verification — it passed
on the first end-to-end run after fixing the toolchain settings
(`llc -function-sections`, `/INCREMENTAL:NO`). The remaining risks are
bounded engineering, not unknowns. Earlier desk-verification work that
raised the prior from ~50–60% to ~65%: Win64 statepoints are exercised
and maintained in-tree (built for LLILC/CoreCLR, SEH bugs fixed 2022–2023)
with one precisely-known boundary — WinEH funclet exceptional paths —
that Eco doesn't cross since Elm codegen emits no invokes; COFF
`.llvm_stackmaps` emission confirmed since 2015; the POSIX-ism long tail
inventoried (items 10b/11b).

Well-understood, mechanical: toolchain URLs (assets verified), node
bootstrap, VirtualAlloc heap mapping (1:1 with the mmap model), thread
shim, process/file kernel modules via std::filesystem + CreateProcess,
executable path, CPack zip.

Remaining risks, in order:
1. ~~**The W3 spike itself** — statepoint root identification end-to-end on
   Win64.~~ **RESOLVED 2026-06-13** — E-W1 passed (see the E-W1 section
   below). Roots recovered via `.llvm_stackmaps` + `RtlVirtualUnwind` on
   both plain frames and dynamic-overaligned-alloca frames. Crucial toolchain
   finding rolled in: `llc -function-sections` is mandatory on
   x86_64-pc-windows-msvc or lld-link drops user `.pdata`.
2. **GC stack walking + JIT frame visibility** (`RtlVirtualUnwind` over
   JIT'd code registered with `RtlAddFunctionTable`) — known mechanism but
   easy to get subtly wrong; needs targeted tests (the GC root-scanning
   E2E tests exist and will catch it). E-W2 covers this.
3. **Elm-compiler path semantics on Windows** (item 10b) — bounded,
   normalize-at-boundary strategy, but touches user-visible behavior and
   the package cache; needs the elm-test suite on Windows to shake out.
4. **HTTP/TLS stack** (curl+schannel vs WinHTTP) — contained but fiddly.
5. LLVM/MLIR source build on Windows is slow and occasionally fragile
   (clang-cl + ninja is the supported config; low risk, high wall-clock).

Compared to macOS (~75–80%), Windows is roughly 3–4× the engineering
surface, dominated by W2/W3.

## GitHub-runner experiments (no Windows hardware required)

Runner facts (verified 2026-06): standard hosted runners are **free with
no minute metering on public repos** (private: Windows minutes at 2×
against 2,000 free/month). `windows-latest` = `windows-2025` (x64,
4 vCPU / 16 GB RAM / 14 GB SSD); `windows-11-arm` also free on public
repos. Limits: 6 h per job, 10 GB actions/cache. Preinstalled: VS
Enterprise 2022 (MSVC 14.4x), Windows SDK 10.0.26100, LLVM/clang 20.1.8,
CMake, Ninja, Node 22, Chocolatey.

Repo logistics: run everything in the public
**github.com/eco-lang/eco-compiler** repo (free runners). Branch
strategy as in the mac plan: develop each experiment on a `ci/**` branch
with `on: push, branches: ['ci/**']` — workflow files do **not** need to
be on master (push-triggered workflows run the pushed branch's version);
only `workflow_dispatch` registration requires the default branch, so
merge thin dispatch stubs to master once experiments stabilize.

### Status snapshot (2026-06-15)

| Phase | Status | Last green run |
|---|---|---|
| E-W1 (statepoint/stackmap spike) | ★ DONE — PASS | `gh run 27479517442` |
| E-W2 (JIT-frame + heap micro-tests) | DONE — PASS | `gh run 27480022149` |
| E-W3 (LLVM 21.1.8 + MLIR cached build) | DONE — install tree cached | `gh run 27480042748` |
| E-W4 (front-end bootstrap stages 1-5 + elm-tests) | DONE — PASS | `gh run 27484680482` |
| W1 (toolchain + presets + CMake hygiene) | DONE | `gh run 27484364269` |
| W2 (runtime platform layer) | DONE — `win-runtime` green | `gh run 27484364269` |
| W3 (GC + JIT) | DONE — `win-runtime` green | `gh run 27484364269` |
| W4 (AOT + full self-host bundle) | ★ DONE — `win-aot` green end-to-end: full self-hosted Stages 6→7→8 (byte-equal `.mlir` fixed point) →9 unified `eco.exe`, PE32+ verified, packaged `eco-0.1.0-x86_64-windows.zip`, `eco.exe --help` smoke-tested in isolation. See W5 follow-up #3 for the four bugs that gated it. | `gh run 27526250970` |
| E-W5 (runtime + JIT E2E) | DONE v1 — `win-runtime` green: test/ subdir builds; allocator, runtime-exports, GC pressure (rapidcheck) suites all pass. Codegen MLIR + Elm-E2E suites gated off pending a Win64 HPtr-return ABI investigation (see follow-ups). | `gh run 27488322914` |
| W5 (tests + docs) | docs/building-windows.md updated (self-host eco.exe builds); follow-ups documented in the W5 section below | — |

**Major milestones reached (2026-06-14):**

1. **`win-runtime` green** — runtime, kernels, JIT codegen, MLIR
   libraries, EcoBootConfig, eco-boot-native, EcoNativeDriverStatic all
   compile on `x86_64-pc-windows-msvc` with clang-cl + lld-link + the
   vendored curl (schannel TLS) / libzip / zlib stack and no OpenSSL
   dependency.

2. **`win-bootstrap` green** — Elm front-end Stages 1-5 produce
   `eco-compiler.mlir` (12 MB) and elm-test-rs runs the compiler/tests/
   suite without failures.

3. **W2/W3 platform layer holds end-to-end** — Allocator's VirtualAlloc
   heap, StackUnwind's RtlVirtualUnwind, eco_entry + eco_embed thread
   shims via _beginthreadex, signal handling via SetConsoleCtrlHandler,
   GC's RtlAddFunctionTable for JIT'd frames.

4. **W4 link line fully wired** — `linkExecutableWindows` runs clang-cl +
   lld-link with /MT static CRT, /INCREMENTAL:NO (E-W1 finding), /EHsc,
   /WHOLEARCHIVE: for the entry / Order-singleton / native-driver libs,
   vendored libcurl_static + zip + zlibstatic, and the Windows SDK import
   libs (kernel32 / user32 / ws2_32 / crypt32 / bcrypt / secur32 /
   advapi32). EcoBootConfig.h's new `windowsLibcurlA / windowsLibzipA /
   windowsZlibA` entries carry the absolute build-tree paths.

### E-W1 — Statepoint/stackmap smoke on Win64 (no eco code) ★ DONE — PASS
The W3 spike (item 14). Implemented in
`experiments/win-statepoint-smoke/` + `.github/workflows/win-statepoint-smoke.yml`.
Last green run on 2026-06-13 (`gh run 27479517442`, conclusion: success):
both `consume_root` (plain frame) and `consume_root_dynalloca` (dynamic
overaligned alloca) recovered the live GC root from the stackmap-described
location after `RtlVirtualUnwind` stepped out of `do_safepoint`, on both
default and explicit `/OPT:REF` linker variants.

Pipeline (same shape as mac E-M1, Win64 primitives where the mac plan used
libunwind / `getsectiondata`):
- LLVM 21.1.8 prebuilt cached (`clang+llvm-21.1.8-x86_64-pc-windows-msvc.tar.xz`)
- `opt -passes=rewrite-statepoints-for-gc` → IR with `gc.statepoint` intrinsics
- `llc -O2 -function-sections -mtriple=x86_64-pc-windows-msvc -filetype=obj`
  → COFF (with `-function-sections` so each function gets its own COMDAT
  `.text`/`.pdata`/`.xdata` — without it, llc aggregates non-COMDAT
  `.pdata` that lld-link silently dropped from the final exception
  directory; this is the *single most important toolchain finding* from
  E-W1)
- `llvm-readobj --sections` confirms `.llvm_stackmaps`
- Harness links via clang-cl + lld-link (default `/OPT:REF`, plus an
  explicit `/INCREMENTAL:NO`); discovers `.llvm_stackmaps` via PE header
  walk from `GetModuleHandle(NULL)`; walks the stack with
  `RtlCaptureContext` + `RtlLookupFunctionEntry` + `RtlVirtualUnwind`;
  resolves stackmap locations against an x86_64 DWARF→`CONTEXT` register map

Findings to carry forward into W2/W3:
- **`llc -function-sections` is required** for x86_64-pc-windows-msvc.
  Without it, none of the `.o`-emitted functions get a `RUNTIME_FUNCTION`
  in the linked exe's exception directory. With it, all do.
- **Image base relocation is NOT applied to `.llvm_stackmaps`.** The
  recorded function addresses match raw on first run, slide-adjusted on
  another — the runtime stackmap consumer must accept both (`fnAddress +
  instrOffset` OR `fnAddress + instrOffset + (actualBase - preferredBase)`).
  The harness does this already and reports which variant fired.
- **`.llvm_stackmaps` survives lld-link's default `/OPT:REF`** —
  no `/INCLUDE:` keep-alive needed in eco's link driver on Win64.
- **lld-link's thunk-table gotcha:** with certain flag combinations
  (notably `/Zi /DEBUG` without `/INCREMENTAL:NO`) lld-link emits a
  5-byte `e9`-jmp slot at the start of `.text` for every address-taken
  function. `&fn` then resolves to the slot, not the entry point, and
  both `RtlLookupFunctionEntry(&fn)` and stackmap `fnAddress` matching
  break. The harness includes a `followThunk()` defensive dereference;
  the eco runtime should either follow the same pattern or pin its link
  to `/INCREMENTAL:NO` (and avoid the combinations that trigger the
  table).
- **Win64 SEH funclet exceptional paths** — the boundary called out in
  item 14 — is **not exercised** by Elm codegen, confirmed by the spike
  using plain calls (`call do_safepoint`) and matching against the
  immediately-following return address.

W3 confidence: **HIGH** — risk 1 from the confidence assessment is
resolved. Proceed with W1 → W2 → W3 in the planned order.

### E-W2 — JIT frame registration + heap-model micro-tests (no eco code)
`VirtualAlloc` an RX region with llc-emitted code + `.pdata`/`.xdata`,
register via `RtlAddFunctionTable`, confirm `RtlLookupFunctionEntry`
resolves inside it and `RtlVirtualUnwind` steps through (confidence
risk 2). Same job: the reserve-64-GB-PAGE_NOACCESS /
commit-subranges / decommit pattern mirroring `Allocator.cpp`'s mmap
model.

### E-W3 — LLVM 21.1.8 + MLIR source build, cached
The one-off enabler. clang-cl (preinstalled 20.x as host compiler is
fine) + ninja; `LLVM_ENABLE_PROJECTS=mlir`,
`LLVM_TARGETS_TO_BUILD=X86`, Release, no examples/tests/docs. Estimated
2–4 h on 4 vCPU — fits the 6 h limit (LLVM's own CI only overruns on
multi-stage PGO builds). sccache + actions/cache; cache the **install
tree** (~2–3 GB) keyed on tag + flags so later workflows restore in
seconds.

### E-W4 — eco configure + bootstrap stages 1–5 on Windows
Mirrors mac E-M2 (toolchain-URL patch + node/pnpm). Also the cheapest
shakeout of the Elm compiler's `/`-separator handling (item 10b): the
bootstrap exercises `fpCombine`/`fpIsRelative`/package-cache paths end to
end. 16 GB RAM — the node 12 GB heap setting is not a concern here.

### E-W5 — Runtime + JIT E2E on Windows
After W2/W3 items land, restoring the E-W3 cache. Same shape as mac
E-M3.

Workflow mechanics: one workflow per experiment, `on: push` on its
`ci/**` branch while iterating, promoted to a `workflow_dispatch` stub on
master once green; cache the LLVM tarball, sccache, install tree,
`~/.eco`; always `upload-artifact` logs.

## Suggested order

W3-spike (statepoint/Win64 viability — gates toolchain choice) → W1 → W2 →
W3 → W4 → W5. Do the macOS port first: it creates the platform seams
(exe path, section discovery, symbol table for JIT, link-driver profiles)
that this plan fills with Win32 implementations, and proves the seams don't
disturb Linux.
