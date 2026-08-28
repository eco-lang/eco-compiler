# Inline the nursery bump-state TLS read — `ECO_INLINE_BUMP_STATE`

**Status: COMPLETE 2026-08-28 — correct and structurally better, but WALL IS FLAT
(−0.03 %). §3's 2–3 % prediction did not materialise; see §4.2.**
Lead surfaced by the survivor call census
(`plans/call-survivor-census.md` §4.1): `eco_bump_state` is the single largest
row in the whole census at **10,462,396,845 surviving calls**.

---

## 1. The finding

HEAP_034 (`plans/inline-nursery-allocation.md`) inlined the nursery bump
*arithmetic* into compiled code — load ptr/end, add, compare, store — leaving
exactly one call on the allocation fast path: `eco_bump_state()`, which fetches
the address of the calling thread's `{ptr, end}` struct
(`EcoBackend.cpp:1218-1226`).

Its body is already call-free (Run L, `benchmarks/tier2-opt.md`): a single
`initial-exec` TLS read of `Allocator::tl_heap_` plus two constant offsets
(`RuntimeExports.cpp:184`). But it lives in `libEcoRuntimeStatic`, which LLVM
never sees while optimizing generated code (no LTO), so every allocation pays
a real `call`/`ret` **and** the caller-saved register clobber that a call
implies at every allocation site.

Scale check (same census run): 376 GB reclaimed / 10.46 B calls ≈ **36 bytes
per call**, matching the nursery size histogram (24–64 B dominant). So the
count is ~1 per allocation — the `memory(none)` CSE is not collapsing these.
The GC counter's "411.6 M objects allocated" undercounts by ~25× because
inline allocations bypass it (the recorded `ECO_INLINE_ALLOC=0` census rule).

## 2. The change

Emit the TLS read directly in `expandInlineAllocs` instead of calling into the
runtime.

**Why not reuse `Allocator::tl_heap_` + a constant offset:** it is a *private*
static member of a C++ class, so the backend would have to hard-code a mangled
symbol name AND `offsetof` two private members — fragile against any compiler
or layout change, with a silent-miscompile failure mode.

**Chosen design — a dedicated exported TLS pointer.** The runtime publishes

```cpp
extern "C" constinit thread_local void* eco_tl_bump_state
    __attribute__((tls_model("initial-exec")));
```

holding exactly what `eco_bump_state()` returns. `extern "C"` kills the
mangling problem; caching the final address kills the offset problem. The
address is thread-stable for the heap's lifetime — `nursery_` is a direct
member of `ThreadLocalHeap` (`ThreadLocalHeap.hpp:210`) and `bump_` a direct
member of `NurserySpace`, so `&bump_` never moves; only its contents change
(minor GC), and the expansion re-loads those per allocation as today
(`NurserySpace.hpp:43-60`).

Codegen then emits, per allocation site:

```llvm
%a     = call ptr @llvm.threadlocal.address(ptr @eco_tl_bump_state)
%state = load ptr, ptr %a, align 8
```

replacing `%state = call ptr @eco_bump_state()`. Everything downstream (the
ptr/end loads, the compare, the diamond, the CGEN_074 unchecked form) is
untouched.

### 2.1 Coherence — the one real risk

A stale `eco_tl_bump_state` is heap corruption, not a wrong number. The
mitigation is structural, not vigilance: `tl_heap_` has exactly four
assignment sites (`Allocator.cpp:267, 282, 306, 820`), all of which become
calls to one private helper

```cpp
static void Allocator::setThreadHeap(ThreadLocalHeap* h);   // sets BOTH
```

so the two can never disagree by construction. `eco_bump_state()` stays,
unchanged, as the JIT path and the escape hatch.

### 2.2 JIT is excluded

ORC cannot generally resolve an `initial-exec` TLS reference from JIT'd code
(the TLS block is allocated by the loader, not the JIT). `expandInlineAllocs`
therefore takes an `allowTls` parameter, passed
`job.kind == BackendKind::EmitObjectFile`. The JIT keeps the call, which
already works and is mapped in `RuntimeSymbols.cpp:96`.

### 2.3 Flag

`ECO_INLINE_BUMP_STATE=0` disables (default ON), matching HEAP_034's
`ECO_INLINE_ALLOC` idiom — a backend env read once through a named
`static const bool` predicate. Backend-only: it changes the emitted binary,
never the `.mlir`, so an existing artifact can be re-lowered both ways.

## 3. Expected effect, and the one way it could regress

Per allocation: `call` + `ret` + ~3 body instructions + caller-saved clobber
(≈5–7 instructions) becomes 2 instructions with no clobber. At 10.46 B events
and ~3 cycles saved, ≈ 31 G cycles ≈ **10 s ≈ 2 % of a 460 s self-compile**.
The register-pressure relief at every allocation site is plausibly the larger
half and is not captured by that arithmetic.

**Counter-risk to measure, not assume:** `eco_bump_state` is `memory(none)` +
`speculatable`, so LLVM may hoist a call out of a loop entirely, whereas a
plain load can be re-issued after any opaque call (the cold
`eco_alloc_inline_slow` edge clobbers memory as far as LLVM knows). If the
call were being hoisted aggressively, inlining could *increase* the number of
state fetches. The census argues it is not (≈1 call per allocation), but the
wall A/B is the arbiter. `!invariant.load` would recover the CSE and is
deliberately NOT used: the pointer is null before `initThread` and after
teardown, so the claim would be false.

## 4. Validation

1. **Build** backend + runtime.
2. **`--target check`** (E2E). Justified over `--target full`: this change
   touches only C++ (runtime + backend), no Elm and no `.mlir` regeneration —
   exactly the CLAUDE.md carve-out.
3. **Self-compile output byte-identity** — re-lower the stored
   `eco-compiler.mlir` both ways; each binary self-compiles to a byte-identical
   `out.mlir`. This is the correctness gate that matters: a stale or wrong
   bump-state address corrupts the heap long before it produces a clean
   14,978,231 B artifact.
4. **Census re-run** (`ECO_CALL_CENSUS=1`) — `eco_bump_state` must fall to
   **0** in the `runtime` bucket; everything else should move only by run
   jitter (~1e-5). Wall A/B against the recorded 7:39.34 census-on leg.

## 4.1 Implementation notes (what the plan missed)

- **There are TWO bump-state emitters, not one.** `applyCapacityHoisting`
  (CGEN_074, `EcoBackend.cpp`) fetches the bump state for its hoisted ensure
  as well as `expandInlineAllocs` doing so for the alloc diamond. Found by
  dumping IR after the first edit: 11 TLS reads but 2 residual
  `eco_bump_state` calls. Both now route through one shared
  `emitBumpStateAddr` helper and both take `allowTls`.
- **The §3 CSE counter-risk is real and visible.** On one small module the
  flag-off leg emits **12** `eco_bump_state` calls where the flag-on leg emits
  **13** TLS fetches: the `memory(none)` call CSE'd one pair that the loads do
  not. Confirms the mechanism; the wall A/B decides whether it matters
  (2 cheap instructions × 13 vs a call × 12).
- `IRBuilder::CreateThreadLocalAddress` + `InitialExecTLSModel` on an
  `ExternalLinkage` `GlobalVariable` is the whole codegen surface; LLVM 21.1.8
  lowers it to the `%fs`-relative form with no `__tls_get_addr`.
- `eco-boot-native` spells the IR dump `--dump-pre-rs4gc-ir=<path>` (no
  `--dump-post-rs4gc-ir`), and dumping the full compiler module is too slow to
  be a check — use a small `build/test/elm-core/eco-stuff/mlir/*.mlir`.

## 4.2 RESULTS — a clean negative on wall, a clean positive on structure

Two cold self-compiles per leg, same stored `eco-compiler.mlir` re-lowered each
way, same workload. **Census-OFF (the honest wall A/B):**

| | pre-change | post-change | delta |
|---|---:|---:|---:|
| wall | 7:29.00 | 7:28.85 | **−0.15 s (−0.03 %) = FLAT** |
| `sat` | 2,219,899,087 | 2,219,899,087 | 0 (identical) |
| output | 14,978,231 B | 14,978,231 B | BYTE-IDENTICAL |

**Census-ON**, same pair: 7:39.34 → 7:31.46, and that −7.88 s is NOT the
optimization — roughly 3.4 s is the census itself getting cheaper (10.46 B
sites stopped being calls, so they stopped being instrumented), and the rest
does not survive into the census-off comparison. Quoting the census-on delta
as the win would have been a measurement error; it was caught by running the
census-off leg rather than reasoning about it.

What DID move, all verified:

- `runtime` bucket 20,741,222,712 → 10,278,727,421, i.e. **−10,462,495,291** —
  matching the measured `eco_bump_state` count (10,462,396,845) to within
  98,446 events (~1e-5 run jitter). The row is gone.
- **`elm` −73,153,799 (−0.91 %)**, far outside jitter: dropping a call from
  every allocation site made bodies smaller and more inlinable, so LLVM
  inlined away Elm calls it previously could not. Unpredicted second-order win.
- Surviving call sites 553,757 → 429,759 (−22.4 %).
- E2E 1,706/1,706; self-compile output byte-identical on every leg.

**Why flat — the §3 counter-risk was the right worry.** `eco_bump_state` was
`memory(none)` + `speculatable`, so LLVM CSE'd and hoisted it; plain TLS loads
are re-issued after any opaque call. The small-module probe showed the shape
directly (12 calls → 13 TLS fetches, §4.1). We traded fewer-but-costlier
fetches for more-but-cheaper ones and the two roughly cancelled. On top of
that the deleted call was already a perfectly-predicted direct call to a
6-instruction leaf, which an out-of-order core hides, and the self-compile is
GC- and memory-bound (135 s of 460 s in the allocator alone), so ALU/call
cycles on the allocation path are not the critical resource.

**Disposition: ship.** It is correct (E2E green, byte-identical output),
deletes 10.46 B call instructions and 124 k call sites, and improves inlining
by 73 M calls — the same "ships for the deleted calls, not a measured win"
basis as `stringLengthOp` (wall −0.12 %) and `appendSplit` (wall +0.80 %),
both default-on in `Config.elm` on exactly this reasoning. `ECO_INLINE_BUMP_STATE=0`
is the escape hatch if a future workload disagrees.

**Lesson for the next census-driven lead:** a large *count* is not a large
*cost*. The census ranks by events, and the top row was a cheap, well-predicted,
already-CSE'd call in a memory-bound phase. Rank candidates by
events × per-event cost × criticality, not events alone.

## 5. Out of scope

- Threading `%state` through hot paths as an explicit parameter (a bigger,
  ABI-level change; revisit only if the TLS load itself shows up).
- The other large `runtime` rows (`eco_string_cmp3` 3.04 B, the GC
  stack-range triplet ~1.99 B × 3) — separate leads from the same census.
