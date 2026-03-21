# Using elm-optimize-level-2 with the Eco Compiler

## Overview

[elm-optimize-level-2](https://github.com/mdgriffith/elm-optimize-level-2) is a
post-processor that applies additional JS-to-JS optimizations to Elm's compiled
output. It can be run directly on the `.js` files produced by guida/eco-boot
without needing to invoke `elm make`.

## Usage

Apply to any compiled JS file by passing it as input:

```bash
cd /work/compiler/build-kernel

# Default optimizations
npx elm-optimize-level-2 bin/eco-boot-2.js --output bin/eco-boot-2-o2.js

# Maximum speed optimizations (recommended — see results below)
npx elm-optimize-level-2 bin/eco-boot-2.js --output bin/eco-boot-2-o3.js -O3
```

Create a corresponding runner script:

```bash
echo 'const { Elm } = require("./eco-boot-2-o3.js"); Elm.Terminal.Main.init();' \
    > bin/eco-boot-2-o3-runner.js
```

Then use the runner in place of `eco-boot-2-runner.js`:

```bash
node --stack-size=65536 bin/eco-boot-2-o3-runner.js make \
    --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```

## What it does

The default transforms include:
- **variantShapes** — normalizes custom type constructor shapes for V8
- **inlineEquality** — inlines `_Utils_eq` for known types
- **inlineFunctions** — inlines F2/F3/A2/A3 wrapper calls
- **passUnwrappedFunctions** — passes raw functions instead of wrapped ones
- **fastCurriedFns** — faster function wrapper implementations
- **replaceListFunctions** — replaces elm/core List functions with faster versions

The `-O3` flag additionally enables:
- **recordUpdates** — optimizes `_Utils_update` record update calls

## Results

O3 gave the best results. Warm Stage 5 timings (average of 2 runs):

| Version | Time | Speedup |
|---------|------|---------|
| Original | 39.3s | — |
| Default (O2) | 35.9s | 8.8% faster |
| **O3 (recommended)** | **33.5s** | **14.9% faster** |

Output is identical — all three versions produce byte-identical MLIR.
File size increases ~22% due to inlining (6.0 MB → 7.3 MB).

## Notes

- The deprecation warnings from TypeScript are harmless and can be ignored.
- The optimized JS is not a fixed-point compiler — do not use it for
  self-compilation (stages 2-4). Use it only for Stage 5 (MLIR generation)
  or other one-shot compilation tasks.
- Apply after `build-verify.sh` confirms the fixed point, so the input
  JS is known-correct.
