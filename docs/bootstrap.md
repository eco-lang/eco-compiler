# Bootstrap Pipeline

The Eco compiler bootstraps through 9 stages:
- Stages 1–4 produce a fixed-point JS compiler.
- Stage 5 uses it to emit MLIR for the native code path, with the light `subst`
  monomorphization engine.
- Stage 6 compiles that MLIR to a native ELF front-end.
- Stage 7 uses the native compiler to re-emit itself with the optimizing
  default engine (solver + LSS), and Stage 8 verifies a native fixed point.
- Stage 9 lowers Stage 7's optimized MLIR into a single user-facing `eco`
  binary: front-end and lowering back-end together, a drop-in replacement for
  `elm make`.

## Which MLIR feeds which binary

| MLIR | Produced by | Mono engine | Lowered into |
|---|---|---|---|
| `eco-compiler.mlir` | Stage 5 (`eco-boot-2.js`, Node) | `subst` (`ECO_MONO_ENGINE=subst`, set by the recipe) | Stage 6 `eco-compiler` only |
| `eco-compiler-boot.mlir` | Stage 7a (`eco-compiler`, native) | default: solver + LSS | Stage 7b `eco-compiler-boot` **and** Stage 9 `eco` |
| `eco-compiler-boot-2.mlir` | Stage 8a (`eco-compiler-boot`, native) | default: solver + LSS | Stage 8b `eco-compiler-boot-2` (fixed-point check only) |

Stage 5 uses `subst` because it is the lightest engine on the Node heap, and its
only job is a *correct* native front-end. Its output is less optimized than
solver + LSS, so nothing that ships is built from it.

Each stage has a dedicated CMake target. Building any later stage transitively
builds all preceding stages, so a clean tree can run the whole chain with a
single command — see [Running the whole pipeline](#running-the-whole-pipeline).

## Test gates

Two E2E test gates fail-fast on backend regressions:

- **Gate A** (after Stage 1) runs the JIT E2E suite through Stage 1's
  `guida.js`. A failure pins the regression to Stage 1 or the runtime, before
  any self-compile cycles burn.
- **Gate B** (after Stages 3+4) runs the AOT E2E suite. A failure pins the
  regression to Stage 5's MLIR codegen or to `eco-boot-native`.

## Prerequisites

One-time CMake configure (only on a fresh checkout, or after touching CMake
itself):

```bash
cmake --preset build
```

Node.js needs a 12 GB heap for self-compilation (Stages 2+):

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
```

## Stages

### Stage 1 — stock Elm compiler → `guida.js`

The stock Elm compiler (from npm) compiles the Eco compiler source using
XHR-based IO. This stage builds **without** `--optimize`, because the XHR
variant of `Eco.Crash` uses `Debug.todo` (forbidden under `--optimize`). From
Stage 2 onward the kernel variant of `Eco.Crash` is used instead, enabling
`--optimize`.

```bash
cmake --build build --target guida
```

Output: `build/compiler/build-xhr/bin/guida.js`

#### Gate A — JIT E2E suite

The `full` target wraps clean + a default rebuild (which includes Stage 1) +
the JIT E2E suite, so it is the one-shot equivalent of Gate A from a dirty
tree:

```bash
cmake --build build --target full
```

### Stage 2 — `guida.js` self-compiles → `eco-boot.js`

The XHR-based compiler compiles itself with kernel IO enabled, producing a
compiler that uses `Eco.Kernel.*` directly.

```bash
cmake --build build --target eco-boot
```

Output: `build/compiler/build-kernel/bin/eco-boot.js`

### Stages 3 & 4 — JS fixed-point verification

Two more self-compilation rounds verify the compiler reproduces itself
identically:

- **Stage 3**: `eco-boot.js` compiles itself → `eco-boot-2.js`
- **Stage 4**: `eco-boot-2.js` compiles itself → `eco-boot-3.js`, then diffs
  `eco-boot-2.js` against `eco-boot-3.js` — they must be identical (fixed point
  reached).

```bash
cmake --build build --target eco-boot-verify
```

#### Gate B — AOT E2E suite

With `eco-boot-2.js` produced and verified, run the AOT E2E suite. It compiles
each Elm E2E test via `eco-boot-2.js`, lowers to native ELF via
`eco-boot-native`, runs the binary, and verifies stdout against `-- CHECK:`
patterns.

```bash
cmake --build build --target run-aot-e2e
```

### Stage 5 — `eco-boot-2.js` → `eco-compiler.mlir`

The fixed-point verified compiler compiles itself to MLIR, exercising the
native code-generation path.
- The recipe first wipes any stale `.ecot` typed-object caches, which
  Stages 2–4 do not invalidate.
- It runs with `ECO_MONO_ENGINE=subst`, which keeps Node's heap pressure down.
- This MLIR is used only to build the Stage 6 front-end.

```bash
cmake --build build --target eco-compiler-mlir
```

Output: `build/compiler/build-kernel/bin/eco-compiler.mlir`

### Stage 6 — `eco-compiler.mlir` → native ELF

The `eco-boot-native` tool lowers the MLIR through the full pipeline (Eco
dialect → LLVM dialect → LLVM IR → object file), then links with the runtime
and kernel static libraries to produce a standalone x86-64 Linux ELF.

```bash
cmake --build build --target eco-compiler
```

Output: `build/compiler/build-kernel/bin/eco-compiler`

### Stage 7 — native compiler self-compiles → `eco-compiler-boot`

- **7a:** the native ELF compiler from Stage 6 compiles itself to
  `eco-compiler-boot.mlir`. It uses the compiler's default monomorphization
  engine, solver + LSS, so this is the optimized MLIR.
- **7b:** `eco-boot-native` lowers that MLIR to a fully bootstrapped native
  executable.

Stage 9 reuses the same MLIR.

```bash
cmake --build build --target eco-compiler-boot
```

Output: `build/compiler/build-kernel/bin/eco-compiler-boot`

### Stage 8 — native fixed-point verification

A second self-compilation round verifies that the bootstrapped compiler
reproduces itself identically.
- **8a:** `eco-compiler-boot` compiles itself to `eco-compiler-boot-2.mlir`
  (solver + LSS).
- **8b:** `eco-boot-native` lowers it to `eco-compiler-boot-2`.
- **8c:** the result is compared byte-for-byte against `eco-compiler-boot`. On
  macOS and Windows the two `.mlir` files are compared instead.

The `bootstrap` aggregate target chains this in.

```bash
cmake --build build --target bootstrap
```

Output: `build/compiler/build-kernel/bin/eco-compiler-boot-2` (identical to
`eco-compiler-boot`)

### Stage 9 — unified `eco` single-binary compiler

Stage 9 fuses the front-end (Stage 6's `eco-compiler`) and the lowering
back-end (`eco-boot-native`'s MLIR → ELF pipeline) into a single ELF binary
called `eco` — the user-facing drop-in replacement for `elm make`. After Stage
9 there is one tool to install, not three.

It reuses Stage 7a's optimized `eco-compiler-boot.mlir`. This is the MLIR whose
lowering passed the Stage 8 fixed point, not Stage 5's `subst`-engine output.
- **9a:** CMake runs `eco-boot-native --emit=obj
  --internalize-keep=eco_main,__eco_init_globals` on that MLIR, gated on the
  Stage 8c stamp.
- **9 link:** it links the object with `EcoEntryStatic`,
`EcoRuntimeStatic`, every `ElmKernel_*` / `EcoKernel_*` static library, and
`EcoNativeDriverStatic`. The link uses GNU ld (`-fuse-ld=bfd`) because lld
rejects the absolute relocations the Elm-compiled object carries in its
`.llvm_stackmaps` section.

The `eco-quick` dev target relinks `eco` from the same `eco-compiler-boot.mlir`
without the Stage 8c gate. Use it when iterating on runtime or kernel C++ after
one full bootstrap.

CLI shape — output kind dispatched by extension:

```
eco make src/Main.elm --output=foo            # → ELF executable "foo"
eco make src/Main.elm --output=foo.js         # → JavaScript
eco make src/Main.elm --output=foo.html       # → HTML
eco make src/Main.elm --output=foo.mlir       # → MLIR text
```

```bash
cmake --build build --target eco
```

Output: `build/compiler/build-kernel/bin/eco`

#### Stage 9b check — unified-binary self-compile

`eco` self-compiles to a second binary, `eco-2`. A successful self-compile is
the success criterion — there is deliberately **no** `eco == eco-2`
byte-equality check (only `eco` embeds the LLVM/MLIR back-end, so the two
binaries differ by construction). The meaningful native fixed-point check is
Stage 8, which compares two non-unified compilers.

```bash
cmake --build build --target eco-verify
```

Output: `build/compiler/build-kernel/bin/eco-2`

## Running the whole pipeline

Each stage in sequence, with both E2E gates:

```bash
export NODE_OPTIONS="--max-old-space-size=12000"

cmake --build build --target guida                # Stage 1
cmake --build build --target full                 # Gate A: JIT E2E suite
cmake --build build --target eco-boot             # Stage 2
cmake --build build --target eco-boot-verify      # Stages 3+4 + JS fixed-point check
cmake --build build --target run-aot-e2e          # Gate B: AOT E2E suite
cmake --build build --target eco-compiler-mlir    # Stage 5
cmake --build build --target eco-compiler         # Stage 6
cmake --build build --target eco-compiler-boot    # Stage 7
cmake --build build --target eco                  # Stage 9: unified single binary
cmake --build build --target bootstrap            # Stages 8 + 9 + all fixed-point checks
```

CMake handles inter-target dependencies, so any target can be built in
isolation from a clean tree — earlier stages build on demand. The minimal
one-shot equivalent (skipping the two E2E gates) is just:

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cmake --build build --target bootstrap
```
