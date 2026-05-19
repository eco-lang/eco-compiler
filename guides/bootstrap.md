# Bootstrap Process

The Eco compiler bootstraps through 8 stages. Stages 1–4 produce a fixed-point JS compiler; stage 5 uses it to emit MLIR for the native code path; stage 6 compiles that MLIR to a native ELF executable; stages 7–8 use the native compiler to self-compile and verify a native fixed point.

Two E2E test gates fail-fast on backend regressions: **Gate A** after Stage 1 runs the JIT E2E suite; **Gate B** after Stages 3+4 runs the AOT E2E suite. Either gate's failure pins the regression to the stages preceding it, before further self-compile cycles burn.

## Prerequisites

Node.js needs a 12 GB heap for self-compilation (stages 2+):

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
cd /work/compiler
./scripts/build.sh bin
```

Output: `build/compiler/build-xhr/bin/guida.js`

### Gate A: JIT E2E test suite

With `guida.js` built, run the JIT E2E suite. This validates Stage 1's frontend plus the entire MLIR-codegen + runtime + JIT stack BEFORE we burn cycles on Stages 2–5's self-compiles. A failure here is localised to Stage 1 or the runtime, not a self-compile interaction.

```bash
cmake --build build --target full
```

### Stage 2: `guida.js` self-compiles → `eco-boot.js`

The XHR-based compiler compiles itself with kernel IO enabled:

```bash
cd /work/compiler
./scripts/build-self.sh bin
```

This runs `guida.js` via the Node.js mock XHR server with `--kernel-package eco/compiler` and `--local-package eco/kernel=...`, producing a compiler that uses `Eco.Kernel.*` directly.

Output: `build/compiler/build-kernel/bin/eco-boot.js`

### Stages 3 & 4: Fixed-point verification

Two more self-compilation rounds verify the compiler reproduces itself identically:

```bash
cd /work/compiler
./scripts/build-verify.sh
```

- **Stage 3**: `eco-boot.js` compiles itself → `eco-boot-2.js`
- **Stage 4**: `eco-boot-2.js` compiles itself → `eco-boot-3.js`
- Diffs the two outputs — they must be identical (fixed point reached).

### Gate B: AOT E2E test suite

With `eco-boot-2.js` produced and verified, run the AOT E2E suite. It compiles each Elm E2E test via Stage 3's `eco-boot-2.js`, lowers to native ELF via `eco-boot-native`, runs the binary, and verifies stdout against `-- CHECK:` patterns. This is the earliest valid point for the AOT gate: failures here pin a regression to Stage 5's MLIR-codegen or to `eco-boot-native` itself, before Stages 5–8's self-compile cycles.

```bash
cmake --build build --target run-aot-e2e
```

Outputs land under `build/test/aot-e2e/<pkg>/` so they coexist with the JIT E2E outputs at `build/test/<pkg>/`.

### Stage 5: `eco-boot-2.js` → `eco-compiler.mlir`

The fixed-point verified compiler compiles itself to MLIR, exercising the native code generation path.

**Important:** Stages 2–4 (JS output) do not write or invalidate `.ecot` typed-object caches. Stale `.ecot` files from a previous MLIR build will cause crashes during monomorphization (e.g. `Union not found: SCC`). Clean these caches before running Stage 5:

```bash
# Clean stale local typed-object caches before Stage 5
find /work/build/compiler/build-kernel/eco-stuff -name '*.ecot' -delete
```

```bash
cd /work/build/compiler/build-kernel
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Output: `build/compiler/build-kernel/bin/eco-compiler.mlir`

### Stage 6: `eco-compiler.mlir` → native ELF executable

The `eco-boot-native` tool (built by CMake from `runtime/src/codegen/eco-boot.cpp`) lowers the MLIR through the full pipeline — Eco dialect → LLVM dialect → LLVM IR → object file — then links with the runtime and kernel static libraries to produce a standalone x86-64 Linux ELF executable.

```bash
# Build eco-boot-native (and all runtime/kernel libraries it links against)
cmake --preset ninja-clang-lld-linux
cmake --build build --target eco-boot-native

# Compile the MLIR to a native executable
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler
```

Output: `build/compiler/build-kernel/bin/eco-compiler`

### Stage 7: Native compiler self-compiles → `eco-compiler-boot`

The native ELF compiler from Stage 6 compiles itself to MLIR, then `eco-boot-native` lowers that MLIR to a fully bootstrapped native executable.

```bash
cd /work/build/compiler/build-kernel
bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm

cd /work
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler-boot.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler-boot
```

Output: `build/compiler/build-kernel/bin/eco-compiler-boot`

### Stage 8: Native fixed-point verification

A second self-compilation round verifies the bootstrapped compiler reproduces itself identically:

```bash
cd /work/build/compiler/build-kernel
bin/eco-compiler-boot make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot-2.mlir \
    /work/compiler/src/Terminal/Main.elm

cd /work
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler-boot-2.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler-boot-2

# Binary compare — must be identical (fixed point reached)
cmp build/compiler/build-kernel/bin/eco-compiler-boot \
    build/compiler/build-kernel/bin/eco-compiler-boot-2
```

Output: `build/compiler/build-kernel/bin/eco-compiler-boot-2` (identical to `eco-compiler-boot`)

## All stages in sequence

Stage 1 builds **without** `--optimize` (the XHR `Eco.Crash` uses `Debug.todo`). Stages 2–5 use `--optimize` (enabled by the kernel `Eco.Crash` which delegates to `Eco.Kernel.Crash` instead of `Debug.todo`). Stages 6–8 produce and verify a fully bootstrapped native compiler.

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cd /work/compiler
./scripts/build.sh bin          # Stage 1: stock Elm (no --optimize) → guida.js
cd /work
cmake --build build --target full  # Gate A: JIT E2E suite
cd /work/compiler
./scripts/build-self.sh bin     # Stage 2: guida.js --optimize → eco-boot.js
./scripts/build-verify.sh       # Stages 3+4: --optimize fixed-point check
cd /work
cmake --build build --target run-aot-e2e  # Gate B: AOT E2E suite
# Clean stale local typed-object caches before Stage 5
find /work/build/compiler/build-kernel/eco-stuff -name '*.ecot' -delete
cd /work/build/compiler/build-kernel
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm  # Stage 5: MLIR output
cd /work
cmake --build build --target eco-boot-native
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler  # Stage 6: native ELF
cd build/compiler/build-kernel
bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm       # Stage 7: native self-compile
cd /work
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler-boot.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler-boot
cd build/compiler/build-kernel
bin/eco-compiler-boot make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot-2.mlir \
    /work/compiler/src/Terminal/Main.elm       # Stage 8: fixed-point verify
cd /work
./build/runtime/src/codegen/eco-boot-native \
    build/compiler/build-kernel/bin/eco-compiler-boot-2.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler-boot-2
cmp build/compiler/build-kernel/bin/eco-compiler-boot \
    build/compiler/build-kernel/bin/eco-compiler-boot-2   # Must match
```
