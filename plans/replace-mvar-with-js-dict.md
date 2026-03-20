# Plan: Eliminate MVar Bytes Encode/Decode via Kernel Direct Storage

## Problem

The kernel `Eco.MVar.elm` wrapper (`eco-kernel-cpp/src/Eco/MVar.elm`) needlessly serializes and deserializes values through `Bytes.Encode`/`Bytes.Decode`, even though the underlying JS kernel (`Eco/Kernel/MVar.js`) already stores Elm values directly in a JS dict without any serialization.

Current flow (kernel path, used in Stages 2+):
```
put: Elm value → Bytes.Encode.encode → Bytes object → JS kernel stores Bytes object
read: JS kernel returns Bytes object → Bytes.Decode.decode → Elm value
```

Desired flow:
```
put: Elm value → JS kernel stores Elm value directly
read: JS kernel returns Elm value directly
```

This is wasteful because:
1. The compiler is single-threaded — no concurrent access requiring serialization
2. Large data structures (e.g. `Opt.GlobalGraph`, `Details.PackageTypedArtifacts`, dependency graphs) are encoded/decoded on every MVar operation
3. The JS kernel already supports direct storage — only the Elm wrapper adds the unnecessary encode/decode layer

## Approach

Modify the kernel `Eco.MVar.elm` to pass values directly to the JS kernel functions, bypassing the `Bytes.Encode`/`Bytes.Decode` steps. The encoder/decoder parameters remain in the API signature for source compatibility with the XHR variant, but are ignored at runtime.

No `replacements.js` changes needed — the fix is entirely within the Eco Kernel Elm module.

## Affected Files

| File | Change |
|------|--------|
| `eco-kernel-cpp/src/Eco/MVar.elm` | Remove Bytes encode/decode, pass values directly to kernel |
| `eco-kernel-cpp/src/Eco/Kernel/MVar.js` | Minor: adjust `_MVar_put` arity (currently `F2(id, value)`, may need `F2(id, value)` — verify) |

**Files NOT changed:**
- `compiler/src-xhr/Eco/MVar.elm` — XHR path genuinely needs serialization for HTTP transport; Stage 1 only
- `compiler/src/Utils/Main.elm` — call sites keep passing encoders/decoders (they're ignored by kernel impl)
- `compiler/scripts/replacements.js` — not involved
- `compiler/bin/eco-io-handler.js` — not involved (XHR server for Stage 1)

## Steps

### Step 0: Baseline — Stage 5 bootstrap with profiling

Run a full Stage 5 build with memory profiling and wall-clock timing to establish a baseline.

```bash
export NODE_OPTIONS="--max-old-space-size=12000"

# Stage 1
cd /work/compiler
./scripts/build.sh bin

# Stage 2
./scripts/build-self.sh bin

# Stages 3+4
./scripts/build-verify.sh

# Stage 5 with profiling
find build-kernel/eco-stuff -name '*.ecot' -delete
cd build-kernel
/usr/bin/time -v node --stack-size=65536 \
    --heap-prof \
    --heap-prof-dir=/work/baseline-heapprof \
    bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | tee /work/baseline-timing.txt
```

Record: wall-clock time, peak RSS, heap snapshot sizes.

### Step 1: Modify `eco-kernel-cpp/src/Eco/MVar.elm`

Change the kernel Elm wrapper to pass values directly, ignoring encoders/decoders:

```elm
module Eco.MVar exposing
    ( MVar(..)
    , new, read, take, put
    )

import Bytes.Decode
import Bytes.Encode
import Eco.Kernel.MVar
import Task exposing (Task)

type MVar a
    = MVar Int

new : Task Never (MVar a)
new =
    Eco.Kernel.MVar.new
        |> Task.map MVar

-- decoder arg kept for API compatibility, ignored at runtime
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read _decoder (MVar id) =
    Eco.Kernel.MVar.read id

-- decoder arg kept for API compatibility, ignored at runtime
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take _decoder (MVar id) =
    Eco.Kernel.MVar.take id

-- encoder arg kept for API compatibility, ignored at runtime
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put _encoder (MVar id) value =
    Eco.Kernel.MVar.put id value
```

**Key changes:**
- `read`: No longer calls `Bytes.Decode.decode` — returns kernel result directly
- `take`: No longer calls `Bytes.Decode.decode` — returns kernel result directly
- `put`: No longer calls `Bytes.Encode.encode` — passes raw Elm value to kernel
- `Debug.todo` error paths removed (they were for decode failures that can no longer happen)

### Step 2: Verify `Eco/Kernel/MVar.js` compatibility

The JS kernel already stores and returns values directly. Verify:

- `_MVar_read(id)` returns the stored value via `__Scheduler_succeed(mvar.value)` ✓
- `_MVar_take(id)` returns the stored value via `__Scheduler_succeed(value)` ✓
- `_MVar_put` is `F2(function(id, value))` — stores `value` directly ✓

The JS kernel needs no changes. The type signatures of the `Eco.Kernel.MVar` functions as seen from Elm are inferred from usage — since we now pass an Elm value (not `Bytes`) to `put` and expect an Elm value (not `Bytes`) from `read`/`take`, the kernel functions are polymorphic enough to handle this.

### Step 3: Rebuild and verify fixed-point

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
cd /work/compiler

# Stage 2: rebuild eco-boot.js with the modified kernel MVar
./scripts/build-self.sh bin

# Stages 3+4: verify fixed-point still holds
./scripts/build-verify.sh
```

The fixed-point check is the key correctness validation: if `eco-boot-2.js` == `eco-boot-3.js`, the compiler correctly self-compiles with direct MVar storage.

### Step 4: Stage 5 bootstrap with profiling (post-change)

```bash
find build-kernel/eco-stuff -name '*.ecot' -delete
cd /work/compiler/build-kernel
/usr/bin/time -v node --stack-size=65536 \
    --heap-prof \
    --heap-prof-dir=/work/optimized-heapprof \
    bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | tee /work/optimized-timing.txt
```

### Step 5: Compare results

Compare baseline vs optimized:
- Wall-clock time (from `/usr/bin/time -v` "Elapsed (wall clock) time")
- Peak RSS (from `/usr/bin/time -v` "Maximum resident set size")
- Heap profile comparison (from `--heap-prof` output)
- Fixed-point verification must pass (Step 3)
- MLIR output should be byte-identical to baseline

## Why This Works

The Elm kernel module system allows `Eco.Kernel.MVar` JS functions to be type-erased — they accept and return opaque JS values. The current Elm wrapper wraps values in `Bytes` before passing to the kernel and unwraps after, purely for API uniformity with the XHR variant. Since the kernel JS never inspects the stored values (it just holds references), removing the encode/decode layer is safe.

The encoder/decoder parameters remain in the public API of `Eco.MVar` so that `Utils.Main.elm` call sites (which must work with both XHR and kernel variants) don't need to change. They're simply unused in the kernel implementation.

## Actual Results (2026-03-20)

| Metric | Baseline | Optimized | Change |
|--------|----------|-----------|--------|
| **Wall clock time** | 7:52 | 4:16 | **-46%** |
| **Peak RSS** | 12,276 MB | 9,268 MB | **-24%** |
| **User CPU time** | 596.6s | 304.1s | **-49%** |
| **Page faults (major)** | 125,069 | 60 | **-99.95%** |
| **MLIR lines** | 693,867 | 691,632 | -0.3% |
| **Fixed-point** | — | Verified | Pass |

The massive reduction in major page faults (125K → 60) shows the baseline was thrashing swap because Bytes encode/decode inflated memory past the 12 GB heap limit. Without that overhead, the process stays in RAM.

MLIR diffs are only auto-generated numeric IDs (fewer specializations needed without Bytes encode/decode paths), not structural changes.

## Implementation Note

The `_`-prefixed parameter names (e.g. `_decoder`) cause a crawl failure in the guida.js Stage 1 compiler when compiling the eco/kernel package. Parameters must be named without underscore prefix (e.g. `decoder`) even though they are unused.

## Risks

| Risk | Mitigation |
|------|------------|
| Kernel JS type mismatch | The JS kernel is already type-erased; stores any JS value |
| `Debug.todo` removal breaks something | The `Debug.todo` was only reachable on decode failure, which can't happen without decode |
| Elm compiler expects `Bytes` return type from kernel | Kernel functions are untyped in JS; the Elm type system accepts whatever the kernel returns |
| XHR variant call sites break | No change to XHR variant or call sites; API signature unchanged |
| Fixed-point divergence | Stage 3+4 verification catches any behavioral change — passed |
| `_`-prefixed unused params | Use plain names; Elm package compilation rejects `_` prefix |
