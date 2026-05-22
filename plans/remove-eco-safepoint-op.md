# Plan: Remove `eco.safepoint`, Move Hints to GCRootCarrier Ops

## Background

`eco.safepoint` is a no-result variadic-operand op carrying a list of `!eco.value`
SSA values that the front-end believes might be live across this point. Its
runtime story today:

- The Elm front-end emits it at sites that *might* allocate or call (string/list/
  tuple/record/custom/closure construction, kernel calls, back-edge jumps,
  string-equality pattern matches, platform-leaf path).
- `EcoGCPrepare` Step 3 walks every `SafepointOp`, computes per-block SSA liveness,
  and **unions** that with the op's existing operands; the union is the load-
  bearing role because per-block `Liveness` is blind to cross-iteration uses of
  values captured into nested `scf.while` / `scf.if` regions.
- `EcoGCPrepare` also treats `SafepointOp` as an allocation-grouping barrier
  (`isGroupBarrier`).
- `SafepointOpLowering` in `EcoToLLVMErrorDebug.cpp` erases the op as a no-op.
  All actual statepoints are inserted later by LLVM's `RewriteStatepointsForGC`
  at call sites in functions tagged with the `eco-gc` strategy.

Other GCRootCarrier ops (`eco.allocate*`, `eco.construct.*`, alloc list/tuple
ops) already carry their own `live_roots` segments via
`centralize-gc-roots-on-alloc-ops.md`. **`eco.call`, `eco.papExtend`, and
`eco.papCreate` do *not* take hints from Elm today** — they are emitted with
zero appended roots and rely entirely on `EcoGCPrepare` Step 4's liveness query
for their final root set. Cross-region values reach those calls today *only*
because the preceding `eco.safepoint` keeps them as visible uses for MLIR's
`Liveness`. Removing `eco.safepoint` without replacing that hint channel for
call/PAP carriers would lose cross-region root visibility at those sites.

## Goal

Delete `eco.safepoint` from front-end, dialect, and lowering. Move the front-
end hint list onto the GCRootCarrier op that the safepoint was protecting —
including extending the Elm builders for `eco.call` / `eco.papExtend` /
`eco.papCreate` so they accept a `live_roots` hint parameter (parity with the
alloc-op convention from `centralize-gc-roots-on-alloc-ops`). Keep RS4GC
behavior identical (it never saw `eco.safepoint`). Phase 1 keeps the hint set
as conservative as today's `Ctx.liveEcoValueVars`.

Phase 2 (deferred): narrow the hint set under guard of `EcoGCLivenessAudit`.

## Non-Goals

- No change to the runtime safepoint poll API (`__eco_safepoint_poll`,
  `eco_safepoint`). They remain unreferenced from codegen.
- No change to RS4GC integration in `EcoBackend.cpp`.
- No new IR anchor for the loop-back-edge case. That guarantee was never
  delivered by `eco.safepoint` anyway (it's erased before RS4GC); reinstating
  it is a separate piece of work and out of scope here.

---

## Decisions (resolved)

These are settled and drive the steps below.

1. **Call/PAP carriers need a hint channel.** Today `eco.call`,
   `eco.papExtend`, and `eco.papCreate` ship from Elm with zero appended roots
   and are populated by `EcoGCPrepare` Step 4. The safepoint-before-call hint
   provides cross-region visibility via Liveness; removing the safepoint
   without giving those carriers their own Elm-side roots channel would
   regress GC root tracking in nested-region code. Therefore Step 2 of this
   plan extends the Elm builders for those three ops to accept a hint list,
   mirroring the alloc-op pattern. The hints feed the appended-roots operand
   layout described by the `GCRootCarrier` interface comment in
   `Ops.td:30-33`; the existing `eco.gc_roots_count` attribute used by
   `setGCRoots` on those ops gets initialised from the hint list at build
   time.

2. **In-scope-at-carrier is guaranteed by construction.**
   `Ctx.liveEcoValueVars(ctx)` returns only `!eco.value` bindings already
   defined at this point of emission. Attaching them to the very next
   GCRootCarrier in the same block cannot violate dominance (they already
   dominate downstream uses) and cannot cross a region boundary (we attach in
   the same block as we would have emitted the safepoint). No additional
   guard needed.

3. **Loop back-edge: drop the hint.** `Expr.elm:3442-3456` currently emits
   `safepoint; eco.jump`. `eco.jump` is a terminator, not a GCRootCarrier, so
   there is nothing to attach to. Drop the hint at this site. No runtime
   regression: the safepoint was already erased and never produced a poll, so
   non-allocating non-calling loops already lacked GC progress. Tests that
   *assert the textual presence* of `eco.safepoint` at back-edges (likely
   `TailRecFanOutSafepointTest.elm`, possibly others) must be updated or
   removed — they were testing a dead emitter, not a runtime guarantee.

4. **`_operand_types` is Elm-side only.** Confirmed: no C++ in `EcoOps.cpp`,
   the lowering passes, or EcoToLLVM reads this attribute; it's purely a
   pretty-printer hint plus the target of invariant tests CGEN_032 / CGEN_040
   / CGEN_038. Removing it from the deleted safepoint builder is safe and
   doesn't perturb other ops that still carry it.

5. **Golden-file sweep is mandatory and scriptable.** At minimum the 4
   dedicated safepoint codegen tests plus `safepoint_explicit.mlir` need
   updates, and an unknown number of generic `.mlir` snapshots may contain
   stray `eco.safepoint` lines. A `grep -rn "eco.safepoint"` sweep across
   `compiler/tests`, `test`, and `runtime/tests` is the first
   implementation action; if the count is non-trivial, write a one-shot
   stripper script rather than hand-editing.

6. **Builder threading, not a post-pass.** Hints are added to builder
   signatures (matching the alloc-op precedent). No separate Elm-side
   re-pass.

7. **Delete first, narrow later.** Phase 1 deletes the op while keeping hints
   conservatively at today's `Ctx.liveEcoValueVars` set. Phase 2 narrows
   under `EcoGCLivenessAudit`. The defensive alternative (narrow first under
   audit, then delete) buys little — `eco.safepoint` is already erased
   before LLVM and `EcoGCPrepare` correctness is dominated by Liveness, not
   by safepoint operands.

---

## Phase 1 — Delete `eco.safepoint`, route hints through GCRootCarrier ops

### Step 0: Preflight sweep

Before touching code, gather the change surface:

```bash
grep -rn "eco.safepoint\|SafepointOp\|emitSafepoint\|ecoSafepoint" \
    compiler/src compiler/tests test runtime/src runtime/tests design_docs
```

Categorise hits into: front-end emitter call sites, dialect/runtime sources,
test goldens, docs. Confirm the call/PAP builder situation matches Decision 1
by reading the current builders for `ecoCall`, `ecoPapExtend`, `ecoPapCreate`
in `compiler/src/Compiler/Generate/MLIR/Ops.elm` (or wherever they live) and
checking the C++ `setGCRoots`/`getGCRoots` for those ops in
`runtime/src/codegen/EcoOps.cpp`.

### Step 1: Front-end — replace `emitSafepoint` with a hint-list helper

**Files:**
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
- `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Replace
```elm
emitSafepoint : Ctx.Context -> ( Ctx.Context, MlirOp )
emitSafepoint ctx = Ops.ecoSafepoint ctx (Ctx.liveEcoValueVars ctx)
```
with
```elm
emitSafepointHints : Ctx.Context -> List ( String, MlirType )
emitSafepointHints ctx = Ctx.liveEcoValueVars ctx
```

Delete `ecoSafepoint` from `Ops.elm`. After Step 2 it has no callers.

### Step 2: Front-end — thread hints into the next GCRootCarrier op

Every current `emitSafepoint` call site has a pattern like:
```elm
( ctx1, sp ) = emitSafepoint ctx0
( ctx2, op ) = Ops.<carrierBuilder> ctx1 ... args
{ ops = ops0 ++ [ sp, op ], ctx = ctx2, ... }
```

Rewrite to:
```elm
let hints = emitSafepointHints ctx0
( ctx1, op ) = Ops.<carrierBuilder> ctx0 hints ... args
{ ops = ops0 ++ [ op ], ctx = ctx1, ... }
```

Builder updates needed in `Ops.elm`. Per Decision 1, every GCRootCarrier
builder gets a `List (String, MlirType)` hint parameter. Two operand-layout
groups:

- **Dedicated `$live_roots` segment** (hint occupies the entire op's input
  list or precedes a fixed scalar/operand): `eco.allocate`, `eco.allocate_ctor`,
  `eco.allocate_string`, `eco.allocate_closure`, `eco.list_construct`,
  `eco.tuple2_construct`, `eco.tuple3_construct`, `eco.box`. Many of these
  already accept roots from prior work — audit per builder and only modify
  those that don't yet.
- **Roots appended after fields/args** (hint goes at the tail and
  `eco.gc_roots_count` records the count): `eco.construct.record`,
  `eco.construct.custom`, `eco.call`, `eco.papExtend`, `eco.papCreate`. For
  `eco.call`/`eco.papExtend`/`eco.papCreate` this is **new** Elm-side work
  (per Decision 1) — confirm the appended-root layout against the C++
  `setGCRoots` for each op before wiring, and emit `eco.gc_roots_count` from
  Elm so the C++ accessor finds the roots at the same offset.

Call sites to update (non-exhaustive — Step 0 sweep is authoritative):

- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — ~25 occurrences (string
  literals, list/tuple/record/custom/closure construction, kernel calls,
  case/if branch entry, fan-out, etc.).
- `compiler/src/Compiler/Generate/MLIR/Functions.elm` — lines 57, 632, 831,
  1038, 1048 (function setup, platform-leaf path).
- `compiler/src/Compiler/Generate/MLIR/Patterns.elm` — lines 214-244
  (string-equality pattern match).

**Sites with no following GCRootCarrier op:**
- Back-edge `eco.jump` (`Expr.elm:3442-3456`): drop the hint per Decision 3.
- Any other emitter that emits `safepoint` followed by something *not* in
  the carrier list: drop the hint and note the site in the commit message.
  These are bugs in the current emitter (the safepoint was decorative there).

### Step 3: Dialect — delete `Eco_SafepointOp`

**Files:**
- `runtime/src/codegen/Ops.td:1536-1564` — delete the `Eco_SafepointOp` def.
- `runtime/src/codegen/EcoOps.cpp:868-871` — delete the `getGCRoots` /
  `setGCRoots` inline implementations for `SafepointOp`.
- `runtime/src/codegen/EcoOps.h` and any other dialect header — remove forward
  refs if any.

Run TableGen and rebuild. Dangling references become compile errors and serve
as a checklist for Step 4 / Step 5 cleanup.

### Step 4: Lowering — delete `SafepointOpLowering`

**File:** `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:33-47, 246`

- Remove the `SafepointOpLowering` struct.
- Remove the `patterns.add<SafepointOpLowering>(...)` registration in
  `populateErrorDebugLoweringPatterns` (or whichever helper around line 246).
- Update the file's header comment (lines 1-6, 21-31) to drop "safepoint" from
  the listed ops and delete the aspirational
  "eco.safepoint -> gc.statepoint + gc.relocate" block — it never matched
  reality and would be doubly misleading after deletion.

### Step 5: `EcoGCPrepare` — drop SafepointOp dependence

**File:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

1. **`isGroupBarrier`** (lines 109-124): remove the
   `if (isa<eco::SafepointOp>(op)) return true;` case. Calls, terminators,
   and PAP ops remain barriers. Allocation groups that were previously split
   by a safepoint will now coalesce up to the 32 KiB threshold. This is
   benign — the leader's liveness query gives the union of all live roots at
   its position, and grouped members share that set by design.

2. **Step 3** (lines 289-323): delete the entire loop that walks `SafepointOp`
   and rewrites operands. Steps 2 and 4 already union liveness with each
   carrier's own `getGCRoots()`; with Step 2 of this plan, the carrier's
   front-end hint *is* the data Step 3 used to provide.

3. File header comment (lines 1-13): drop bullet (5) and any mention of
   `eco.safepoint` in bullet (1).

### Step 6: Tests and docs

**Test sweep:** based on Step 0 grep, expect at minimum:

- `compiler/tests/TestLogic/Generate/CodeGen/SafepointRegionScopingTest.elm`
- `compiler/tests/TestLogic/Generate/CodeGen/SafepointRegionScoping.elm`
- `test/elm/src/TailRecFanOutSafepointTest.elm` (back-edge — see Decision 3)
- `compiler/tests/SourceIR/IfLetSafepointCases.elm`
- `compiler/tests/SourceIR/CaseSafepointLeakCases.elm`
- `test/elm/src/IfLetSafepointTest.elm`
- `test/elm/src/CaseSafepointLeakTest.elm`
- `runtime/tests/.../safepoint_explicit.mlir` (or wherever this lives)
- Any other `.mlir` snapshot containing `eco.safepoint`

For each:
- Behavioural cases (`*Leak*`, `*RegionScoping*`) — assertions about *which
  values are tracked as GC roots through nested regions* must continue to
  pass. Retarget assertions from `eco.safepoint` operand lines to the
  GCRootCarrier op's `live_roots` segment / appended-root operands. If they
  fail after retargeting, the bug is in Step 2's builder threading.
- Pure-textual presence cases (likely `TailRecFanOutSafepointTest`) — update
  or remove, per Decision 3.
- Generic `.mlir` snapshots — if more than ~10, write a sed/awk script that
  drops standalone `eco.safepoint ...` lines and re-record.

**Docs:**
- `design_docs/theory/pass_eco_to_llvm_theory.md` — rewrite any text
  describing `eco.safepoint` as a front-end marker.
- `design_docs/invariants.csv` — search for `safepoint` entries; remove or
  reword. Keep invariants that refer to the *abstract safepoint concept*
  (RS4GC-managed call statepoints); delete ones that refer to the deleted
  op specifically. CGEN_032/CGEN_038/CGEN_040 (referencing `_operand_types`)
  remain — they apply to other ops, not the now-deleted safepoint.
- `THEORY.md` — same audit.
- `runtime/src/codegen/Passes.h` — update `createEcoGCPreparePass` comments
  to drop "safepoints" from the carrier list and remove the bullet
  describing safepoint root recomputation.

### Step 7: Verify RS4GC output unchanged

- Build with `-DECO_LOWERING_VALIDATION=ON` so `EcoGCLivenessAudit` runs
  after `EcoGCPrepare`.
- Run the full E2E (`cmake --build build --target full`).
- For a representative test (one with nested `scf.while` / closure capture —
  e.g. one of the `*Leak*` or `*RegionScoping*` cases), dump pre/post-RS4GC
  LLVM IR via `dumpRS4GCIR` before and after the change. Diff. Expected
  differences are limited to (a) `eco.safepoint` no longer present in the
  pre-RS4GC dump (it was already a no-op in the post dump), and (b) possibly
  larger alloc groups. There should be no change to the set of `gc.statepoint`
  / `gc.relocate` instructions in the post-RS4GC IR.

- If `EcoGCLivenessAudit` fires on any test, the failing site is a hint-
  threading bug in Step 2: the safepoint there was providing visibility for a
  value that the new path didn't carry onto the carrier op.

---

## Phase 2 — Narrow hints, with `EcoGCLivenessAudit` as guard (deferred)

### Step 8: Ensure `EcoGCLivenessAudit` runs in CI

Already wired into `EcoPipeline.cpp:81` under `ECO_LOWERING_VALIDATION`. Make
sure at least one CI configuration enables it so Phase 2 regressions surface
automatically.

### Step 9: Tighten `Ctx.liveEcoValueVars`

Today this returns every in-scope `!eco.value` binding in `definedSsaVars`.
Candidate narrowings, in increasing order of aggression:

1. Drop variables whose defining op precedes the *previous* GCRootCarrier in
   the same block (their liveness was already established at that prior
   carrier).
2. Drop variables that are syntactically dead in the remainder of the
   function.
3. Empty.

Iterate; if the audit fails on tightened settings, back off to the previous
level for the affected pattern and document why.

### Step 10: Remove the hint channel entirely (stretch)

If the audit holds at empty for a full release cycle, drop the hint parameter
from all carrier builders and let `EcoGCPrepare` Steps 2 and 4 drive root
sets purely from Liveness plus each op's own non-hint operands. This is the
true endpoint — front-end hints disappear and MLIR Liveness is canonical.
