# Bootstrap Process

The Eco compiler bootstraps through 5 stages. Stages 1–4 produce a fixed-point JS compiler; stage 5 uses it to emit MLIR for the native code path.

## Prerequisites

Node.js needs a 16 GB heap for self-compilation (stages 2+):

```bash
export NODE_OPTIONS="--max-old-space-size=16384"
```

## Stages

### Stage 1: Stock Elm compiler → `guida.js`

The stock Elm compiler (from npm) compiles the Eco compiler source using XHR-based IO:

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

The fixed-point verified compiler compiles itself to MLIR, exercising the native code generation path:

```bash
cd /work/compiler/build-kernel
node bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Output: `compiler/build-kernel/bin/eco-compiler.mlir`

## All stages in sequence

```bash
export NODE_OPTIONS="--max-old-space-size=16384"
cd /work/compiler
./scripts/build.sh bin          # Stage 1: stock Elm → guida.js
./scripts/build-self.sh bin     # Stage 2: guida.js → eco-boot.js
./scripts/build-verify.sh       # Stages 3+4: fixed-point check
cd build-kernel
node bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm  # Stage 5: MLIR output
```
