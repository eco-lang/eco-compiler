# Bootstrap Process

The Eco compiler bootstraps through 9 stages. Stages 1–4 produce a fixed-point JS compiler; stage 5 uses it to emit MLIR for the native code path; stage 6 compiles that MLIR to a native ELF executable; stages 7–8 use the native compiler to self-compile and verify a native fixed point. Stage 9 fuses the front-end and the lowering back-end into a single user-facing `eco` binary that is a drop-in replacement for `elm make`.

Each stage has a dedicated CMake target. Building any later stage's target transitively builds all preceding stages, so a clean tree can run the whole chain with a single `cmake --build build --target bootstrap`.

Two E2E test gates fail-fast on backend regressions: **Gate A** after Stage 1 runs the JIT E2E suite through Stage 1's `guida.js` (driven by `compiler/bin/index.js` with the XHR mock + `eco-io-handler.js`); **Gate B** after Stages 3+4 runs the AOT E2E suite. Either gate's failure pins the regression to the stages preceding it, before further self-compile cycles burn.

## Prerequisites

One-time CMake configure (only on a fresh checkout or after touching CMake itself):

```bash
cmake --preset ninja-clang-lld-linux
```

Node.js needs a 12 GB heap for self-compilation (Stages 2+):

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
```

## Stages

### Stage 1: Stock Elm compiler → `guida.js`

The stock Elm compiler (from npm) compiles the Eco compiler source using XHR-based IO.
This stage builds **without** `--optimize` because the XHR variant of `Eco.Crash` uses
`Debug.todo` (which is forbidden by `--optimize`). Starting from Stage 2, the kernel
variant of `Eco.Crash` (via `Eco.Kernel.Crash`) is used instead, enabling `--optimize`.

```bash
cmake --build build --target guida
```

Output: `build/compiler/build-xhr/bin/guida.js`

### Gate A: JIT E2E test suite

With `guida.js` built, run the JIT E2E suite. The JIT runner compiles each Elm test through Stage 1's `compiler/bin/index.js` — a Node wrapper that loads `guida.js` under `mock-xmlhttprequest` and routes IO through `eco-io-handler.js` — then JITs the resulting MLIR. This validates Stage 1's frontend plus the entire MLIR-codegen + runtime + JIT stack BEFORE we burn cycles on Stages 2–5's self-compiles. A failure here is localised to Stage 1 or the runtime, not a downstream self-compile interaction.

The `full` target wraps clean + default-ALL rebuild (which includes Stage 1) + JIT E2E, so it is the one-shot equivalent of running Gate A from a dirty tree:

```bash
cmake --build build --target full
```

### Stage 2: `guida.js` self-compiles → `eco-boot.js`

The XHR-based compiler compiles itself with kernel IO enabled, producing a compiler that uses `Eco.Kernel.*` directly.

```bash
cmake --build build --target eco-boot
```

Output: `build/compiler/build-kernel/bin/eco-boot.js`

### Stages 3 & 4: Fixed-point verification

Two more self-compilation rounds verify the compiler reproduces itself identically:

- **Stage 3**: `eco-boot.js` compiles itself → `eco-boot-2.js`
- **Stage 4**: `eco-boot-2.js` compiles itself → `eco-boot-3.js`, then diffs `eco-boot-2.js` against `eco-boot-3.js` — they must be identical (fixed point reached).

```bash
cmake --build build --target eco-boot-verify
```

### Gate B: AOT E2E test suite

With `eco-boot-2.js` produced and verified, run the AOT E2E suite. It compiles each Elm E2E test via Stage 3's `eco-boot-2.js`, lowers to native ELF via `eco-boot-native`, runs the binary, and verifies stdout against `-- CHECK:` patterns. This is the earliest valid point for the AOT gate: failures here pin a regression to Stage 5's MLIR-codegen or to `eco-boot-native` itself, before Stages 5–8's self-compile cycles.

```bash
cmake --build build --target run-aot-e2e
```

Outputs land under `build/test/aot-e2e/<pkg>/` so they coexist with the JIT E2E outputs at `build/test/<pkg>/`.

### Stage 5: `eco-boot-2.js` → `eco-compiler.mlir`

The fixed-point verified compiler compiles itself to MLIR, exercising the native code generation path.

The target's recipe wipes any stale `.ecot` typed-object caches under `build/compiler/build-kernel/eco-stuff/` before running — Stages 2–4 (JS output) don't write or invalidate those caches, so leftovers from a previous MLIR build would otherwise cause crashes during monomorphization (e.g. `Union not found: SCC`).

```bash
cmake --build build --target eco-compiler-mlir
```

Output: `build/compiler/build-kernel/bin/eco-compiler.mlir`

### Stage 6: `eco-compiler.mlir` → native ELF executable

The `eco-boot-native` tool (built by CMake from `runtime/src/codegen/eco-boot.cpp`) lowers the MLIR through the full pipeline — Eco dialect → LLVM dialect → LLVM IR → object file — then links with the runtime and kernel static libraries to produce a standalone x86-64 Linux ELF executable.

```bash
cmake --build build --target eco-compiler
```

The `eco-compiler` target transitively builds the `eco-boot-native` tool plus all runtime and kernel libraries it links against.

Output: `build/compiler/build-kernel/bin/eco-compiler`

### Stage 7: Native compiler self-compiles → `eco-compiler-boot`

The native ELF compiler from Stage 6 compiles itself to MLIR, then `eco-boot-native` lowers that MLIR to a fully bootstrapped native executable. Both sub-steps are bundled into a single CMake target:

```bash
cmake --build build --target eco-compiler-boot
```

Output: `build/compiler/build-kernel/bin/eco-compiler-boot`

### Stage 8: Native fixed-point verification

A second self-compilation round verifies the bootstrapped compiler reproduces itself identically: `eco-compiler-boot` compiles itself to MLIR, `eco-boot-native` lowers it, and the produced binary is compared byte-for-byte against `eco-compiler-boot`. The `bootstrap` aggregate target chains all three sub-steps plus the final `cmp`:

```bash
cmake --build build --target bootstrap
```

The `bootstrap` target is also the one-shot entry point for the entire chain: on a clean tree it transitively runs every stage from 1 onward, ending with the Stage 4b JS fixed-point check, the Stage 8c intermediate native fixed-point check, and the Stage 9c unified-binary fixed-point check.

Output: `build/compiler/build-kernel/bin/eco-compiler-boot-2` (identical to `eco-compiler-boot`)

### Stage 9: unified `eco` single-binary compiler

The culmination of the bootstrap chain. Stage 9 fuses the front-end (Stage 6's `eco-compiler`) and the lowering back-end (`eco-boot-native`'s MLIR → ELF pipeline) into a single ELF binary called `eco` — the user-facing drop-in replacement for `elm make`. After Stage 9 there is one tool to install, not three.

The two halves are bridged by a small C ABI (`eco_native_lower_and_link` in `runtime/src/codegen/EcoNativeAPI.h`), exposed to the Elm front-end through the `Eco.NativeDriver.lowerAndLink` kernel intrinsic (`EcoKernel_NativeDriver`, sourced from `eco-kernel-cpp/src/eco/NativeDriver.cpp`). When the front-end is asked for an `--output=<path>` whose extension isn't `.js` / `.html` / `.mlir`, `Terminal.Make.handleElfOutput` writes the MLIR text to a temp file under `eco-stuff/<ver>/build/` and invokes the in-process pipeline via the kernel intrinsic; the temp file is removed on success.

`eco` reuses the `eco-compiler.mlir` produced by Stage 5. CMake invokes `eco-boot-native --emit=obj` on that MLIR to produce `eco-stage9.o`, then links the object together with `EcoEntryStatic`, `EcoRuntimeStatic`, every `ElmKernel_*` / `EcoKernel_*` static library, and `EcoNativeDriverStatic`. The strong `eco_native_lower_and_link` symbol from `EcoNativeDriverStatic` overrides the weak stub in `EcoEntryStatic` (see `eco_native_stub.cpp`), so the kernel intrinsic resolves to a working implementation only in `eco`; other AOT binaries fall back to the stub and surface a `Task` failure if the intrinsic is ever invoked.

The link uses GNU ld (`-fuse-ld=bfd`) because lld rejects the absolute `R_X86_64_64` relocations the Elm-compiled object carries in its `.llvm_stackmaps` section (GC safepoint addresses tied to local function symbols).

**Phase 3 — direct linker invocation, no `clang++` driver.** `eco-boot-native::linkExecutable` (and its library twin in `EcoNativeDriverStatic` that the unified `eco` binary's kernel intrinsic calls) invokes `/usr/bin/ld` (GNU ld.bfd) directly rather than going through the `clang++` driver. The crt files (`Scrt1.o`, `crti.o`, `crtn.o`, `crtbeginS.o`, `crtendS.o`), `libgcc.a`, gcc libdir, and library search paths are discovered at CMake configure time via `clang -print-file-name=…` / `-print-search-dirs` and baked into `EcoBootConfig.h`. The dynamic linker is the platform ABI constant `/lib64/ld-linux-x86-64.so.2`. As a result, produced AOT binaries can be built and deployed on a host that has `ld` but no `clang++`. Embedding lld as a library would have been the cleaner end-state, but the LLVM 21 install used by the build does not ship lld dev headers/static libs; using ld.bfd directly achieves the same "no `clang++` runtime dependency" goal.

CLI shape — drop-in for `elm make`, output kind dispatched by extension:

```
eco make src/Main.elm --output=foo            # → ELF executable "foo"
eco make src/Main.elm --output=foo.js         # → JavaScript (existing path)
eco make src/Main.elm --output=foo.html       # → HTML (existing path)
eco make src/Main.elm --output=foo.mlir       # → MLIR text (existing path)
```

```bash
cmake --build build --target eco
```

Output: `build/compiler/build-kernel/bin/eco`

### Stage 9c: unified-binary fixed-point check

`eco` self-compiles to a second copy and the two ELFs are compared bytewise. This is the strongest available fixed-point check — front-end, lowering pipeline, and linker are all pinned as self-consistent.

```bash
cmake --build build --target eco-verify
```

Inherited issue: the Stage 8c native intermediate check has known byte-equality problems that have not yet been fixed; Stage 9c surfaces the same divergences. The fix belongs at the Stage 8 layer, not in the Stage 9 plumbing.

Output: `build/compiler/build-kernel/bin/eco-2` (must be byte-identical to `eco`)

## All stages in sequence

Stage 1 builds **without** `--optimize` (the XHR `Eco.Crash` uses `Debug.todo`). Stages 2–5 use `--optimize` (enabled by the kernel `Eco.Crash` which delegates to `Eco.Kernel.Crash` instead of `Debug.todo`). Stages 6–8 produce and verify a fully bootstrapped native compiler. Stage 9 fuses everything into the user-facing `eco` binary.

```bash
export NODE_OPTIONS="--max-old-space-size=12000"

cmake --build build --target guida                # Stage 1
cmake --build build --target full                 # Gate A: JIT E2E suite via guida.js (XHR)
cmake --build build --target eco-boot             # Stage 2
cmake --build build --target eco-boot-verify      # Stages 3+4 + JS fixed-point check
cmake --build build --target run-aot-e2e          # Gate B: AOT E2E suite
cmake --build build --target eco-compiler-mlir    # Stage 5
cmake --build build --target eco-compiler         # Stage 6
cmake --build build --target eco-compiler-boot    # Stage 7
cmake --build build --target eco                  # Stage 9: unified single binary
cmake --build build --target bootstrap            # Stages 8 + 9 + all fixed-point checks
```

CMake handles dependencies between targets, so any of these targets can also be built in isolation from a clean tree — earlier stages will be built on demand. The minimal one-shot equivalent (skipping the two E2E gates) is just:

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cmake --build build --target bootstrap
```
