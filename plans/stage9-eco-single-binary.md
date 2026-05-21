# Stage 9: `eco` — Single-Binary Elm Compiler

## Goal

Add **Stage 9** to the bootstrap chain: produce a single ELF binary called
`eco` that takes `.elm` sources and writes a standalone x86-64 Linux ELF
executable — a drop-in replacement for `elm`. The primary aim is a working
single-file compiler; throughput/streaming optimizations are scoped into
later phases of this plan rather than blocking the first cut.

After this stage, the bootstrap product the user installs is just `eco`.
`eco-compiler` and `eco-boot-native` continue to exist as internal
bootstrap-stage tools; they're how Stage 9 is built and verified.

## Current state (verified, not assumed)

Two cooperating binaries today:

| Binary | Built from | Input | Output |
|---|---|---|---|
| `eco-compiler` | Elm compiler source, AOT-compiled in Stages 5–6 | `.elm` | `.mlir` (text or bytecode) on disk |
| `eco-boot-native` | C++ driver (`runtime/src/codegen/eco-boot.cpp`) | `.mlir` (or `.elm` via `--frontend=<node-runner>`) | ELF executable on disk |

Boundary today: `eco-compiler` writes MLIR to a file path passed via
`--output=foo.mlir`; `eco-boot-native` parses that file and lowers it
through MLIR → LLVM IR → object file → `clang++` link → ELF.

Streaming primitives already on the Elm side
(`writeMonoMlirStreaming` in `compiler/src/Builder/Generate.elm` →
`Mlir.Pretty.ppModuleHeader/ppTopLevelOp/ppModuleFooter` →
`Eco.File.hWriteString`). Streaming writes chunks to a `Handle`;
nothing yet writes chunks anywhere other than a file.

`main()` ownership in the existing AOT pipeline (relevant to Stage 9
design): `eco_entry.cpp` provides the binary's literal `main()` and is
linked into every ELF produced by `eco-boot-native`. It initializes the
GC/allocator, calls `__eco_init_globals` and
`eco_register_all_effect_managers`, then calls `eco_main()` — which is
the Elm-side `main` renamed by `eco-boot.cpp` after MLIR-to-LLVM
translation:

```cpp
if (auto *mainFn = llvmModule->getFunction("main"))
    mainFn->setName("eco_main");
```

This pattern matches the runtime model: the Elm `main` is a
`Platform.worker` value, not a system `main()` — the C++ runtime
scheduler is what actually drives execution after init.

## Architecture choice

**Single-process, statically linked.** The `eco` binary contains:

1. The Elm front-end compiled to native code (the same artifact that
   today is `eco-compiler`).
2. The MLIR/LLVM lowering pipeline and link-step orchestration (the
   same C++ code that today is `eco-boot-native`), linked in as a
   static library rather than invoked as a child process.
3. **`lld` linked in as a library** (Phase 3) so `eco` does its own
   final link step — no `clang++` / system-linker dependency at
   runtime.

The two halves are bridged by a small C ABI shim. The C++ side owns
`main()` (mirroring `eco_entry.cpp`'s init pattern); the Elm-side
`eco_main()` runs the compiler logic, and the compiler calls the
linked-in back-end via a C ABI entry:

```c
// runtime/src/codegen/EcoNativeAPI.h — new
int eco_native_lower_and_link(
    const char *mlir_bytes, size_t mlir_len,   // text MLIR buffer
    const char *output_path,                   // ELF output path
    const struct EcoNativeOptions *opts);      // optLevel, verbose, etc.
```

Rejected alternatives, with one-line reasons:

- **Subprocess + pipe** (`eco` = front-end ELF that pipes MLIR over
  stdout to a back-end ELF on stdin): doesn't reduce binary count or
  process-management cost; doesn't simplify deployment.
- **Elm side owns `main()`**: would require re-plumbing GC/allocator
  init and Platform.worker startup out of C++ and into Elm. The
  existing `eco_entry.cpp` pattern is the right place for these.
- **In-memory `mlir::Operation` graph instead of text bytes**: would
  require teaching the Elm-side MLIR emitter to build C++-side MLIR
  data structures directly through FFI. Enormous surface area for
  near-zero gain over text bytes — MLIR's text parser is fast enough.
  Bytecode-format MLIR (the streaming-bytecode-encoder plan) is a
  better optimization target if parsing ever shows up in profiles.

## CLI surface

Drop-in replacement for `elm make`:

```
eco make src/Main.elm --output=foo            # → ELF executable "foo"
eco make src/Main.elm --output=foo.js         # → JavaScript (existing path)
eco make src/Main.elm --output=foo.html       # → HTML (existing path)
eco make src/Main.elm --output=foo.mlir       # → MLIR text (existing path)
```

Output kind is dispatched by extension. No `.js` / `.html` / `.mlir`
extension means **emit ELF**. None of `eco-boot-native`'s `cl::opt`
flags (`-O`, `--verbose`, `--lowering-stats`, `--dump-rs4gc-ir`,
`--enable-unboxed-agg`, etc.) are user-facing on `eco` — defaults
only.

## Phased plan

### Phase 1 — Combined binary, file-based boundary

Validates the linkage step (two halves can live in one ELF) without
touching the MLIR transport.

Steps:

1. **Extract `eco-boot-native`'s pipeline into a static library**.
   Split `runtime/src/codegen/eco-boot.cpp` into:
   - `EcoNativeDriver.cpp` (the pipeline: parseMLIR → runPipeline →
     translateToLLVMIR → createTargetMachine → runEcoBackend →
     linkExecutable). Compiled into a new static library
     `EcoNativeDriverStatic`.
   - `eco-boot-native-main.cpp` (a thin `int main()` that parses CLI
     and calls the library). The existing `eco-boot-native` binary
     stays building, linked from the same library + this main.
2. **Add a C ABI entry point** `eco_native_lower_and_link(mlir_path,
   output_path, opts)` in the new library. Takes a file path for now —
   no in-memory transport yet.
3. **New CMake target `eco`** that links:
   - The Elm-compiled compiler object (the same `.o` Stage 6 already
     produces from `eco-compiler.mlir`, with `main` renamed to
     `eco_main` by the existing rename in the driver).
   - `EcoEntryStatic` (provides the `main()` that inits the GC and
     calls `eco_main()` — identical to what user ELFs get today).
   - `EcoNativeDriverStatic` (the lowering+link pipeline).
   - All runtime / kernel / `libcurl` / `libunwind` etc. static libs
     `eco-compiler` already links against.
   The binary's `main()` is therefore the same `eco_entry.cpp` `main`
   that user-emitted ELFs use — no new entry-point code needed.
4. **Plumb the back-end driver into the Elm side via a kernel
   intrinsic.** New Elm kernel module `Eco.Kernel.NativeDriver` with
   `lowerAndLink : String -> String -> Task String ()` (mlirPath →
   elfPath), backed by `Eco_Kernel_NativeDriver_lowerAndLink` in
   `eco-kernel-cpp/src/eco/NativeDriver.cpp`, which calls
   `eco_native_lower_and_link(...)`.
5. **Front-end output dispatch**: extend
   `compiler/src/Terminal/Make.elm` with `handleElfOutput`. When
   `--output` has no `.js` / `.html` / `.mlir` extension, write
   MLIR to a temp file under `eco-stuff/build/eco-NNNN.mlir`, then
   call `Eco.Kernel.NativeDriver.lowerAndLink tempPath outPath`,
   then unlink the temp. Use `eco-stuff/` (not `/tmp`) so the
   MLIR sits next to other build artefacts and benefits from the
   same cache locality as `.ecot` files.
6. **Smoke test**: `eco make compiler/tests/E2E/Hello.elm
   --output=hello && ./hello` produces the same stdout as the AOT
   E2E gate's run of the same test.

Deliverable: a single binary that works end-to-end via an
`eco-stuff/` temp file. `clang++` is still spawned for the final
link (same as today's `eco-boot-native`).

### Phase 2 — In-memory MLIR transport

Validates removing the disk hop.

Steps:

1. **Extend the C ABI** with a buffer-input variant:
   `eco_native_lower_and_link_bytes(const char *mlir_bytes, size_t
   len, const char *output_path, ...)`. Internally constructs an
   `llvm::MemoryBuffer` from the bytes and feeds it to the existing
   `SourceMgr` path.
2. **Add a chunk-collecting writer** on the Elm side. Today's
   `Eco.File.hWriteString` writes to an `fd`. Add a sibling
   `Eco.Kernel.NativeBuf.appendChunk : Int -> String -> Task Never
   ()` backed by a new C++ export
   `Eco_Kernel_NativeBuf_appendChunk(buf, str)` that appends to a
   process-local growable byte buffer keyed by an integer handle.
3. **New writer in `Builder.File`**:
   `withInMemoryWriter : (Int -> (String -> Task Never ()) -> Task
   Never a) -> Task Never (a, Int)` that allocates a fresh native
   buffer, runs the callback (which is `streamMlirToWriter`), and
   returns the buffer handle.
4. **Wire `handleElfOutput` to use the in-memory writer**, then call
   `eco_native_lower_and_link_bytes(buf_ptr, buf_len, output_path)`
   via a new kernel intrinsic. Drop the temp file path.

Deliverable: no `.mlir` ever touches the disk during `eco make
foo.elm --output=foo`.

### Phase 3 — Embed `lld`, drop the `clang++` subprocess

Today `eco-boot-native::linkExecutable` shells out to `clang++` so
the system driver can locate `crt1.o`, `libc.a`, `libgcc.a` and run
`lld`. For a true drop-in replacement, `eco` should do the final
link itself with no system-toolchain dependency.

Steps:

1. **Link `lld::elf` into `EcoNativeDriverStatic`.** LLVM exposes
   `lld::elf::link(args, stdoutOS, stderrOS, /*exitEarly=*/false,
   /*disableOutput=*/false)` as a library entry point.
2. **Discover crt/libc paths at CMake configure time.** Use
   `find_program(clang ...)` + `clang -print-file-name=crt1.o` /
   `-print-runtime-dir` / `-print-libgcc-file-name` once at
   configure time, bake the absolute paths into `EcoBootConfig.h`
   alongside the existing `entryLib` / `runtimeLib` / `elmKernelLibs`
   constants. This is the same pattern Stage 6's static-lib paths
   already use.
3. **Replace `linkExecutable`** with a function that builds the
   argv `lld::elf::link` would receive from `clang++ -static` today,
   then calls the library directly. No process spawn, no PATH
   lookup, no system-clang dependency at run time.
4. **Verify**: a fresh container without `clang` or `clang++`
   installed can still run `eco make foo.elm --output=foo` and
   produce a working ELF.

Note: the AOT-emitted user ELFs use libcurl/libssl/libcrypto/libzip
dynamic libraries (kernel HTTP path). Those stay as `-l` args to
`lld::elf::link`; embedding them is out of scope.

### Phase 4 — Pipelined back-end start

Validates that lowering can begin before the front-end finishes,
reducing wall-clock time.

Trade-off: MLIR's parser expects a complete textual module, so true
chunk-by-chunk parsing isn't free. Two viable approaches; pick one
based on measurement at the end of Phase 2:

- **4a — Thread split, full-buffer parse**: front-end runs on
  thread 1 and appends chunks into a buffer protected by a mutex;
  thread 2 (the back-end driver) starts running as soon as the
  front-end emits the module footer chunk. Gain: back-end startup
  cost (target-machine init, dialect registration, pass-manager
  build) overlaps with front-end's last few percent of work.
- **4b — Per-function streaming via bytecode**: build on
  `streaming-bytecode-encoder.md`. Each isolated `func.func` is a
  self-contained bytecode section; once the front-end has finished
  a func, it can be parsed and lowered while later funcs are still
  generating. Larger change; bigger payoff.

Defer the 4a-vs-4b choice until Phase 1+2 land and we can measure
where the time goes.

### Phase 5 — Bootstrap chain wiring + Stage 9 fixed-point check

Steps:

1. **CMake**: define `eco` target depending on the Stage 6 lowered
   compiler object and `EcoNativeDriverStatic`. Place output at
   `build/compiler/build-kernel/bin/eco`.
2. **Stage 9a — `eco` self-compiles to ELF**. Run `eco make
   compiler/src/Terminal/Main.elm --output=eco-2`, producing a
   second copy of the compiler binary.
3. **Stage 9b — ELF fixed-point check**. `cmake -E compare_files
   eco eco-2`. The two ELFs **must be byte-identical**.

   This is the strongest check available: it pins the *entire*
   compiler binary (front-end + lowering + linker) as a self-consistent
   fixed point. Phase 3's embedded `lld` is what makes this check
   tight — with a spawned `clang++` the link step's behavior would
   depend on the host toolchain, which would weaken the invariant.

   Known issue: Stage 8's ELF byte-equality check
   (`eco-compiler-boot == eco-compiler-boot-2`) currently has open
   problems we haven't fixed. Stage 9 inherits whatever Stage 8
   fails on; that's the point — the Stage 9 check is what makes
   the Stage 8 problem load-bearing, and it should be fixed at
   the Stage 8 layer not papered over here.
4. **`bootstrap` aggregate target** depends on `eco` and the Stage 9
   check.
5. **Update `guides/bootstrap.md`** — add a Stage 9 section after
   Stage 8 describing the single-binary culmination and the full
   ELF fixed-point check.

## File touch list (Phase 1)

| File | Action |
|---|---|
| `runtime/src/codegen/EcoNativeDriver.{h,cpp}` | **Create** — extract pipeline functions from `eco-boot.cpp` |
| `runtime/src/codegen/EcoNativeAPI.h` | **Create** — C ABI: `eco_native_lower_and_link(...)` |
| `runtime/src/codegen/eco-boot.cpp` | **Trim** — keep only `main()` parsing CLI + dispatching to driver lib |
| `runtime/src/codegen/CMakeLists.txt` | **Modify** — add `EcoNativeDriverStatic`; thin `eco-boot-native` link |
| `compiler/CMakeLists.txt` | **Modify** — add `eco` target + Stage 9 commands |
| `compiler/src/Terminal/Make.elm` | **Modify** — `handleElfOutput` branch; extension-driven dispatch |
| `compiler/src/Builder/Generate.elm` | **Modify** — `writeMonoMlirToElf` orchestrator (Phase 1 wraps the temp-file flow) |
| `eco-kernel-cpp/src/eco/NativeDriver.{cpp,hpp}` | **Create** — kernel intrinsic that calls the C ABI entry |
| `eco-kernel-cpp/src/Eco/Kernel/NativeDriver.elm` | **Create** — Elm-side wrapper for the intrinsic |
| `guides/bootstrap.md` | **Modify** — add Stage 9 section |

## Resolved decisions

| # | Decision | Notes |
|---|---|---|
| 1 | CLI: `eco make src/Main.elm --output=foo` | Drop-in replacement for `elm make`; extension-driven dispatch for output kind |
| 2 | `eco-compiler` and `eco-boot-native` stay | Internal Stage 6/7/8 tools; Stage 9 sits on top |
| 3 | Stage 9 check = full ELF byte equality | Stage 8 has known equality issues; those get fixed at the Stage 8 layer, not worked around here |
| 4 | No peak-RSS gating step | Combine first, measure if/when it bites |
| 5 | C++ owns `main()` via existing `eco_entry.cpp` pattern | Elm `main` (a Platform.worker) is renamed to `eco_main`; C++ inits runtime then calls it. No new entry-point code needed |
| 6 | `lld` embedded as a library (Phase 3) | Removes `clang++` and system-linker runtime dependency; load-bearing for the Stage 9 byte-equality check |
| 7 | Temp MLIR (Phase 1 only) lives in `eco-stuff/` | Co-located with other build artefacts; gone entirely after Phase 2 |
| 8 | No user-facing back-end flags | All `cl::opt` knobs hidden, defaults only |
| 9 | x86-64 Linux only | Cross-platform is a separate later program of work |
