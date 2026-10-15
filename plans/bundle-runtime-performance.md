# Plan: runtime performance of programs built by the static musl bundle

## Goal

Programs built by the release bundle's `eco` (static, musl) should run the runtime and kernel code
about as fast as programs built in the dev tree (glibc). Today some workloads take nearly twice as
long.

## Evidence (2026-10-15)

`examples/benchmarks` `Bench.elm`, same source and same machine; `bench` built in the dev tree
(Stage-1 front end, `eco-boot-native`, glibc), `bench-bundle` built by the release bundle's `eco`:

| workload | dev (ms) | bundle (ms) |
|---|---:|---:|
| fannkuch-redux 8 | 70 | 128 |
| sort 100000 | 32 | 57 |
| fasta 50000 | 63 | 89 |
| nsieve 4 | 108 | 142 |

Workloads that run only generated code (fib, list-map, mandelbrot, ...) are as fast or faster in
the bundle. `perf record` over fannkuch-redux and sort (bundle ≈ 202 ms per pass, dev ≈ 110 ms),
costs converted to ms:

| | dev | bundle | extra |
|---|---:|---:|---:|
| malloc/free (musl: `__lock`, `__unlock`, `__libc_free`, `get_meta`, `__libc_malloc_impl`, `alloc_slot`, `nontrivial_free`) | ≈ 11 | ≈ 56 | +45 |
| `Elm::Allocator::resolve` | ≈ 15 | ≈ 28 | +13 |
| `eco_get_tag` | ≈ 2 | ≈ 13 | +11 |
| `Elm::initHeaderForTag` | ≈ 2 | ≈ 12 | +10 |
| `memcpy` | < 1 | ≈ 8 | +7 |

The generated code is not the cause: the bundle's `eco` uses the same defaults as the dev tree
(front end `Config.default`: solver engine, LSS on; backend `EcoNativeOptions`: `-O2`, `cgu`,
auto split, as `eco-boot-native`), and `bench` and `bench-bundle` contain the same 228 generated
functions with identical instructions (they differ only in inter-function padding, `nop` vs
`int3`).

Two causes, both in how the bundle's runtime and kernel archives
(`lib/eco-runtime/project/*.a`) are built and linked, not in eco's code generation:

1. **musl's malloc.** Kernel paths allocate per call through `std::vector` scratch buffers:
   `List.sort`/`sortBy`/`sortWith` (`elm-kernel-cpp/src/core/ListExports.cpp`), `append`,
   `concat` and friends (`runtime/src/allocator/ListOps.cpp`). musl's mallocng is slower than
   glibc's, and takes a global lock (`__lock`/`__unlock`, 12 % of samples alone) on every call
   once a second thread exists, which in eco is always (GC helper threads).
2. **Alpine's hardening defaults.** `docker/llvm-alpine.Dockerfile` builds only `mlir;lld`, so the
   runtime is compiled by Alpine's packaged `clang` (`docker/static-build.Dockerfile` `apk add
   clang`), which enables `-fstack-protector-strong` and `_FORTIFY_SOURCE=2` with Alpine's
   fortify-headers by default. `bench-bundle` has 3,721 `__stack_chk_fail` checks and 1,123
   `ud2` traps (dev build: 0 and 1); `eco_get_tag` is 140 instructions against 45, mostly
   memcpy overlap checks around the runtime's `std::memcpy` bit-casts, and small memcpys stop
   being inlined.

## Work

### A. Build the bundle runtime without Alpine's hardening defaults (done)

- Top-level `CMakeLists.txt`, in the `ECO_STATIC_MUSL` block before any target or FetchContent
  dependency: `add_compile_options(-fno-stack-protector -U_FORTIFY_SOURCE)`, so the runtime,
  kernels, `eco` and the vendored curl/libzip/mimalloc are all built like the dev build. A
  configure check (`check_c_source_compiles`/`check_cxx_source_compiles`) fails the configure
  if `_FORTIFY_SOURCE` or `__SSP*__` is still defined with those flags.
- Not rebuilt, so still hardened: Alpine's own archives (libc++, OpenSSL, zlib) and musl.
- Check on the host: `llvm-objdump -d` of a bundle-built program shows no `__stack_chk_fail`
  calls in eco's runtime functions, and `eco_get_tag` close to the dev build's 45 instructions.

### B. Replace musl's malloc in programs eco builds (done)

- mimalloc v2.5.2 (MIT), vendored with FetchContent in the top-level `CMakeLists.txt` under
  `ECO_STATIC_MUSL` (`MI_LIBC_MUSL`, `MI_OVERRIDE`, object build only). Its single object file
  (`mimalloc-obj`) is linked ahead of every archive, so its `malloc`/`free`/... and musl's internal
  `__libc_malloc`/`__libc_calloc`/`__libc_realloc`/`__libc_free` are the definitions the linker
  takes, and musl's allocator is never pulled in (mimalloc's documented static override).
- Programs eco builds: `eco::config::mimallocObjStatic` in `EcoBootConfig.h`
  (`runtime/src/codegen/CMakeLists.txt`), pushed right after the crt prefix for
  `LinkProfile::MuslStaticExe` (`EcoNativeDriver.cpp`); installed as
  `lib/eco-runtime/mimalloc.o`; `eco-boot-native` depends on it.
- `eco` itself: `$<TARGET_OBJECTS:mimalloc-obj>` added to the target in
  `eco_apply_unified_link` (`compiler/CMakeLists.txt`), so `eco` and `eco-quick` both get it.
- Scope: musl bundle only; glibc, macOS and Windows keep the system allocator.
- Checked locally (no Alpine here): against musl 1.2.5 built from source, a static program with
  mimalloc.o links cleanly, uses mimalloc (`malloc_usable_size` 112 for 100 bytes), contains no
  musl allocator symbols (`alloc_slot`, `get_meta`, `__libc_malloc_impl`), and runs a
  vector-growth loop with a second thread alive in 41 ns per iteration against 296 ns with musl's
  malloc. A standalone CMake project reproducing the vendoring (with Alpine-like
  `-D_FORTIFY_SOURCE=2 -fstack-protector-strong` in `CMAKE_C_FLAGS`) checked the configure
  guard, that `mimalloc.o` has no stack-protector references, `$<TARGET_OBJECTS:mimalloc-obj>` in
  a generated header, the install rule and a static link via `target_sources`. The dev (glibc)
  build reconfigures, `eco-boot-native` rebuilds and links working programs.
- Check on the host: the Docker bundle build (its smoke tests), then `bench`/`node run.mjs` with
  the new bundle; musl's allocator symbols must be absent from a bundle-built program
  (`llvm-nm prog | grep -E 'alloc_slot|get_meta|__libc_malloc_impl'` prints nothing).

### C. Turn off assertions in the release runtime (done)

- Found after A and B: `eco_get_tag` and 274 other eco runtime functions in a bundle-built program
  still called `__assert_fail`, although `ECO_ASSERTS_ON` defaults to OFF for Release "so shipped
  binaries don't pay the runtime cost". Cause: `runtime/src/codegen/CMakeLists.txt` includes
  LLVM's `HandleLLVMOptions`, which adds `-UNDEBUG` to every C/C++ compile in that directory when
  LLVM was built with `LLVM_ENABLE_ASSERTIONS=ON` (both our LLVM images are). That directory owns
  `EcoRuntimeStatic` (allocator, GC, runtime exports), which every program links. The kernel
  archives live in other directories and already honoured `NDEBUG` in Release, so the old bundle
  also mixed assert-on runtime with assert-off kernels.
- Fix: `eco_runtime_asserts(target)` in `runtime/src/codegen/CMakeLists.txt` re-applies
  `ECO_ASSERTS_ON` to the program-side runtime targets (`EcoRuntimeStatic`, `EcoEntryStatic`,
  `EcoEmbedStatic`, `EcoNodeGlue`): `-UNDEBUG` when ON, else `-DNDEBUG` as a compile option, which
  comes after the directory's `-UNDEBUG`. These targets include no LLVM/MLIR headers; the
  LLVM-using targets keep LLVM's setting. Dev builds (`ECO_ASSERTS_ON` ON) are unchanged.
- Safety: all 284 `assert(...)` in the affected sources parsed; none has a side effect (the five
  flagged call `const` getters). No shared header has `NDEBUG`-conditional members.
- Measured (glibc, same generated code, best of two runs): with the runtime's assertions off the
  benchmarks total 796 ms against 816 ms (-2.5 %); sort -10 %, nsieve -10 %; all results correct.

## Open questions

- How much of the gap A and B each close; measure after each with `node run.mjs` and the
  `bench`/`bench-bundle` pair above.
- Whether `eco` itself (the compiler binary, same toolchain) gets faster too; check compile times
  of the bootstrap with the bundle's `eco`.
- The bundle ships no licence notices for its vendored libraries (curl, libzip, OpenSSL, and now
  mimalloc, all of which ask for one); a pre-existing gap for a separate change.
- `docker/llvm-alpine.Dockerfile` builds LLVM with `LLVM_ENABLE_ASSERTIONS=ON`, which slows the
  bundle's `eco` while it compiles (not the programs it builds). Separate decision.

## Status

- 2026-10-15: draft. Causes measured on fannkuch-redux and sort only; nothing implemented.
- 2026-10-15: A and B implemented and checked as far as this (glibc) container allows; the
  Docker bundle build and the before/after benchmark on the host are outstanding.
- 2026-10-15: measured on the host with the rebuilt bundle (`./bench`, median ms; bundle before
  -> after, dev build in brackets): fannkuch-redux 130 -> 67 (70), sort 57 -> 43 (32), fasta
  89 -> 61 (63), nsieve 142 -> 123 (108), nqueens 82 -> 68 (69), float-sum 58 -> 48 (55); the
  generated-code workloads are unchanged. Most of the gap is closed; sort and nsieve remain
  10-35 % behind the dev build (not yet profiled).
- 2026-10-15: the same host run exposed an unrelated bug: the native `String.fromFloat` (and the
  JSON and HTML writers sharing `formatFloatShortest`) did not follow JavaScript's number
  formatting ("1e+09" for 1e9), so the self-hosted `eco` emitted the JS literal `1e+09.0`. Fixed
  in `runtime/src/allocator/StringOps.hpp` (ECMAScript Number::toString; 20,036 values match
  node exactly), plus the JS generator no longer appends ".0" to exponent-form literals.
- 2026-10-15: tests: JIT E2E `check` 2,381/0 (A, B and the formatter); new
  `test/elm/src/StringFromFloatJsFormatTest.elm` (E2E, fails on the old formatter) and two
  `StringOpsTest.cpp` unit tests (JavaScript table, round-trip property) pass; elm-tests
  14,118/0 after the JS generator change. Host follow-up: rebuild the bundle, then
  `node run.mjs` (the self-hosted `eco` needs the formatter fix to emit valid JS).
- 2026-10-15: C implemented (release runtime built with NDEBUG); checked with an
  `ECO_ASSERTS_ON=OFF` build tree: `libEcoRuntimeStatic.a` has no `__assert_fail` references
  (dev: 18 members), programs link and run correctly, -2.5 % total. Host follow-up: rebuild the
  bundle and confirm `eco_get_tag` no longer calls `__assert_fail`.
