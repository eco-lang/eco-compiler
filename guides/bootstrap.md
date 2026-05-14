# Bootstrap Process

The Eco compiler bootstraps through 8 stages. Stages 1–4 produce a fixed-point JS compiler; stage 5 uses it to emit MLIR for the native code path; stage 6 compiles that MLIR to a native ELF executable; stages 7–8 use the native compiler to self-compile and verify a native fixed point.

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

Output: `compiler/build-xhr/bin/guida.js`

### Stage 2: `guida.js` self-compiles → `eco-boot.js`

The XHR-based compiler compiles itself with kernel IO enabled:

```bash
cd /work/compiler
./scripts/build-self.sh bin
```

This runs `guida.js` via the Node.js mock XHR server with `--kernel-package eco/compiler` and `--local-package eco/kernel=...`, producing a compiler that uses `Eco.Kernel.*` directly.

Output: `compiler/build-kernel/bin/eco-boot.js`

### Stages 3 & 4: Fixed-point verification

Two more self-compilation rounds verify the compiler reproduces itself identically:

```bash
cd /work/compiler
./scripts/build-verify.sh
```

- **Stage 3**: `eco-boot.js` compiles itself → `eco-boot-2.js`
- **Stage 4**: `eco-boot-2.js` compiles itself → `eco-boot-3.js`
- Diffs the two outputs — they must be identical (fixed point reached).

### Stage 5: `eco-boot-2.js` → `eco-compiler.mlir`

The fixed-point verified compiler compiles itself to MLIR, exercising the native code generation path.

**Important:** Stages 2–4 (JS output) do not write or invalidate `.ecot` typed-object caches. Stale `.ecot` files from a previous MLIR build will cause crashes during monomorphization (e.g. `Union not found: SCC`). Clean these caches before running Stage 5:

```bash
# Clean stale local typed-object caches before Stage 5
find /work/compiler/build-kernel/eco-stuff -name '*.ecot' -delete
```

```bash
cd /work/compiler/build-kernel
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Output: `compiler/build-kernel/bin/eco-compiler.mlir`

### Stage 6: `eco-compiler.mlir` → native ELF executable

The `eco-boot-native` tool (built by CMake from `runtime/src/codegen/eco-boot.cpp`) lowers the MLIR through the full pipeline — Eco dialect → LLVM dialect → LLVM IR → object file — then links with the runtime and kernel static libraries to produce a standalone x86-64 Linux ELF executable.

```bash
# Build eco-boot-native (and all runtime/kernel libraries it links against)
cmake --preset ninja-clang-lld-linux
cmake --build build --target eco-boot-native

# Compile the MLIR to a native executable
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir \
    -o compiler/build-kernel/bin/eco-compiler
```

Output: `compiler/build-kernel/bin/eco-compiler`

### Stage 7: Native compiler self-compiles → `eco-compiler-boot`

The native ELF compiler from Stage 6 compiles itself to MLIR, then `eco-boot-native` lowers that MLIR to a fully bootstrapped native executable.

```bash
cd /work/compiler/build-kernel
bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm

cd /work
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler-boot.mlir \
    -o compiler/build-kernel/bin/eco-compiler-boot
```

Output: `compiler/build-kernel/bin/eco-compiler-boot`

### Stage 8: Native fixed-point verification

A second self-compilation round verifies the bootstrapped compiler reproduces itself identically:

```bash
cd /work/compiler/build-kernel
bin/eco-compiler-boot make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot-2.mlir \
    /work/compiler/src/Terminal/Main.elm

cd /work
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler-boot-2.mlir \
    -o compiler/build-kernel/bin/eco-compiler-boot-2

# Binary compare — must be identical (fixed point reached)
cmp compiler/build-kernel/bin/eco-compiler-boot \
    compiler/build-kernel/bin/eco-compiler-boot-2
```

Output: `compiler/build-kernel/bin/eco-compiler-boot-2` (identical to `eco-compiler-boot`)

## All stages in sequence

Stage 1 builds **without** `--optimize` (the XHR `Eco.Crash` uses `Debug.todo`). Stages 2–5 use `--optimize` (enabled by the kernel `Eco.Crash` which delegates to `Eco.Kernel.Crash` instead of `Debug.todo`). Stages 6–8 produce and verify a fully bootstrapped native compiler.

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cd /work/compiler
./scripts/build.sh bin          # Stage 1: stock Elm (no --optimize) → guida.js
./scripts/build-self.sh bin     # Stage 2: guida.js --optimize → eco-boot.js
./scripts/build-verify.sh       # Stages 3+4: --optimize fixed-point check
# Clean stale local typed-object caches before Stage 5
find build-kernel/eco-stuff -name '*.ecot' -delete
cd build-kernel
node --stack-size=65536 bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm  # Stage 5: MLIR output
cd /work
cmake --build build --target eco-boot-native
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler.mlir \
    -o compiler/build-kernel/bin/eco-compiler  # Stage 6: native ELF
cd compiler/build-kernel
bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm       # Stage 7: native self-compile
cd /work
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler-boot.mlir \
    -o compiler/build-kernel/bin/eco-compiler-boot
cd compiler/build-kernel
bin/eco-compiler-boot make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot-2.mlir \
    /work/compiler/src/Terminal/Main.elm       # Stage 8: fixed-point verify
cd /work
./build/runtime/src/codegen/eco-boot-native \
    compiler/build-kernel/bin/eco-compiler-boot-2.mlir \
    -o compiler/build-kernel/bin/eco-compiler-boot-2
cmp compiler/build-kernel/bin/eco-compiler-boot \
    compiler/build-kernel/bin/eco-compiler-boot-2   # Must match
```
