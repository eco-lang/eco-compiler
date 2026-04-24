# `eco.papCreateGroup` — mutually-recursive closure construction

## Goal

Replace the per-binding `eco.papCreate` + placeholder/`fixSelfCaptures` pattern
with a single group op when a let-chain contains a mutually-recursive closure
SCC (size ≥ 2). This eliminates the SSA-dominance / forward-reference problem
for mutual let-rec and keeps the GC invariant (no old→young pointers, no write
barrier) by constructing all siblings in the same generation in one runtime
call.

Self-recursion continues to use `self_capture_indices` + `fixSelfCaptures`
unchanged — a self cycle can never create an age disparity.

## Invariants that constrain the design

- REP_* / CGEN_CLOSURE_*: existing closure layout (`Closure` struct,
  `Header`, `values[]`, `unboxed_bitmap`, evaluator pointer) is reused
  verbatim. No new heap shape.
- HEAP_*: no write barrier is added. Correctness hinges on siblings being
  co-allocated in one generation between reservation and cross-edge wiring.
- CGEN_CLOSURE_003 (no cross-function SSA refs): captures that reference
  siblings must not appear as SSA operands; they are expressed as attribute
  edges instead.
- GCRootCarrier contract: any op that calls into the runtime and might GC
  must carry live roots in a tail slice of its operands, and implement
  `getGCRoots` / `setGCRoots` so `EcoGCPrepare` can rewrite them.

## Current baseline (verified)

- `Eco_PapCreateOp` at `runtime/src/codegen/Ops.td:922` — uses
  `DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>` and
  `SymbolUserOpInterface`; captures are variadic operands; `arity`,
  `num_captured`, `unboxed_bitmap`, `_fast_evaluator`, `_closure_kind`
  are attributes.
- `PapCreateOpLowering` at
  `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:561`; runtime entrypoint
  is `eco_alloc_closure(func_ptr, num_captures)` from
  `runtime/src/allocator/RuntimeExports.cpp:333`, registered in
  `RuntimeSymbols.cpp:58`.
- Elm side: `generateLet` at `compiler/src/Compiler/Generate/MLIR/Expr.elm:3565`
  already:
  - collects `boundNames` for the whole chain,
  - installs placeholder SSA vars for every bound name via
    `addPlaceholderMappings` (line 3536),
  - sets `ctx.currentLetSiblings` to the sibling placeholders,
  - runs `generateExpr` on each RHS, then `fixSelfCaptures` (line 215) for
    self-captures, then `forceResultVar` to pin the RHS result to the
    placeholder SSA var.
  The placeholder trick works for self-capture because the capture slot is
  literally rewritten to a Unit and patched later. It does **not** work for
  cross-sibling capture because sibling B's placeholder is not yet defined
  when A's `papCreate` is emitted.

## Plan (step by step)

### Phase 1 — MLIR op

1. **Add `Eco_PapCreateGroupOp`** in `runtime/src/codegen/Ops.td` next to
   `Eco_PapCreateOp`:
   - Traits: `Pure`, `DeclareOpInterfaceMethods<SymbolUserOpInterface>`,
     `DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>`.
   - Operands: `Variadic<Eco_AnyValue>:$operands` — flattened
     non-sibling captures followed by GC roots.
   - Results: `Variadic<Eco_Value>:$closures` — N HPointers, one per
     sibling, in sibling-index order.
   - Attributes:
     - `siblings` : `ArrayAttr` of dictionaries with keys
       `function` (FlatSymbolRef), optional `_fast_evaluator`
       (FlatSymbolRef), `arity` (I64), `num_captured` (I64),
       `unboxed_bitmap` (I64), `capture_indices` (ArrayAttr<I64>).
       `capture_indices[i]` indexes into the shared `operands` list.
     - `cross_edges` : `ArrayAttr` of `[producer, consumer, slot]` I64
       triples.
     - `_operand_types` : mirror of existing `papCreate` for
       CheckEcoClosureCaptures reuse.
   - `hasCustomAssemblyFormat = 1`, `hasVerifier = 1`.

2. **Parser/printer** in `runtime/src/codegen/EcoOps.cpp` following the
   convention used for `PapCreateOp` and other variadic+attr ops. Format:
   ```
   %c0, %c1 = eco.papCreateGroup(%op0, %op1)
     { siblings = [...], cross_edges = [...] }
     : (!eco.value, !eco.value) -> (!eco.value, !eco.value)
   ```

3. **Verifier** in the same file — checks using only local attribute
   data (no pass dependencies):
   - `siblings.size()` equals number of results.
   - `cross_edges` entries are length-3 I64 arrays; producer / consumer
     are in `[0, N)`.
   - **Per-sibling capture-count invariant**: for sibling `i`,
     `num_captured[i] == capture_indices[i].size() +
     count{ (p,c,slot) in cross_edges | c == i }`. This makes
     `num_captured` the single source of truth for `Closure.n_values`.
   - **Cross-edge slot bounds**: `slot < num_captured[consumer]`.
   - **Cross-edge slots are always boxed**: for each
     `(p, c, slot)`, bit `2*slot` of `unboxed_bitmap[c]` must be 0
     (v1 restricts sibling captures to boxed slots; see decision 6).
   - Each sibling's `capture_indices` entries are in range of the
     captures prefix of `operands` (see GCRootCarrier partition below).
   - The callee function-parameter shape check (num_captured vs callee
     arity, capture types) stays in `CheckEcoClosureCaptures`
     (Phase 5, step 15), factored so both `papCreate` and
     `papCreateGroup` share it.

4. **GCRootCarrier methods** for `PapCreateGroupOp` in `EcoOps.cpp`:
   - Partition operands as `[captures..., roots...]` where
     `capturesCount = sum over siblings of capture_indices.size()`.
     This is derivable from the attribute, so `getGCRoots` / `setGCRoots`
     can compute the split deterministically. Document this on the op.
   - `getGCRoots` returns the tail slice; `setGCRoots` replaces it.

### Phase 2 — Runtime allocator

5. **Declare `eco_alloc_closure_group_slow`** in
   `runtime/src/allocator/RuntimeExports.h` next to
   `eco_alloc_closure_slow` (line 163). No `ThreadLocalHeap*`
   parameter — matches the existing `_slow` convention, which reaches
   the allocator via `Allocator::instance()`:
   ```c++
   extern "C" void eco_alloc_closure_group_slow(
     uint64_t           numSiblings,
     const void * const *evaluators,      // [N]
     const uint32_t    *numCaptures,      // [N]   — matches existing API width
     const uint64_t    *unboxedBitmaps,   // [N]
     const uint32_t    *captureOffsets,   // [N+1] — prefix sums into captures[]
     const uint64_t    *captures,         // flattened i64/HPointer values
     const uint64_t    *crossEdges,       // flattened [prod,cons,slot] * M
     uint64_t           numCrossEdges,
     uint64_t          *outClosures       // [N]
   );
   ```

6. **Implement `eco_alloc_closure_group_slow`** in
   `runtime/src/allocator/RuntimeExports.cpp`. Use the **region
   allocator**, not per-sibling `eco_alloc_closure_slow`, so the whole
   group lives in a single contiguous chunk in a single generation:
   - Compute per-sibling closure size
     (`sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures *
     sizeof(Unboxable)`, matching the math in `eco_alloc_closure_slow`
     at `RuntimeExports.cpp:592`). Sum into `totalBytes` with alignment
     padding between siblings.
   - Fast path: `eco_gc_alloc_region_fast(totalBytes)` (line 677). On
     null, fall back to `eco_gc_alloc_region_slow(totalBytes)` (line
     681) — which wraps `Allocator::instance().allocateRegionSlow` and
     handles minor GC + large-object pinning internally. The group
     must **never split across multiple region allocations**; a single
     region call gives us "all siblings in one generation".
   - Initialize each `Closure` header from the shared region using the
     same layout as `eco_alloc_closure_slow` (`n_values = 0`,
     `max_values = num_captures`, `unboxed = unboxedBitmaps[i]`,
     `evaluator = evaluators[i]`). Factor the header-init body out of
     `eco_alloc_closure_slow` into a helper both callers use, rather
     than duplicating layout code.
   - Compute each sibling's HPointer via `ptrToHPointer` and record in
     `outClosures[i]` before writing cross-edges (producers need their
     HPointer available when consumers read it).
   - Write non-sibling captures from `captures[captureOffsets[i]
     .. captureOffsets[i+1])` into `closure->values[slot].as_i64`.
     Bump each sibling's `n_values` to `num_captures` after its slots
     are populated.
   - Wire cross-edges: for each `(prod, cons, slot)`, write
     `outClosures[prod]` into `consumer->values[slot].as_i64`.
     Cross-edge slots are always boxed (see decision 6), so a plain
     i64 store is correct. Same-generation ⇒ no write barrier.
   - No safepoint is permitted between the region allocation and the
     last cross-edge write. The only GC opportunity is inside
     `eco_gc_alloc_region_slow`, before any sibling is initialized.

7. **Register the symbol** in
   `runtime/src/codegen/RuntimeSymbols.cpp` next to `eco_alloc_closure`
   (line 58) so JIT resolves `eco_alloc_closure_group_slow`.

### Phase 3 — EcoToLLVM lowering

8. **Add `getOrCreateAllocClosureGroupSlow`** in
   `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`, mirroring
   `getOrCreateAllocClosure` at line 159. The LLVM signature must
   match `eco_alloc_closure_group_slow` from step 5 exactly.

9. **Add `PapCreateGroupOpLowering`** in
   `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` and register it in
   `populateEcoClosurePatterns` (line 1506). Steps:
   - Split `adaptor.getOperands()` into `captures` / `roots` using the
     same partition the GCRootCarrier interface uses (derived from
     `capture_indices` lengths).
   - Materialize five LLVM module-global constant arrays:
     `evaluators`, `numCaptures`, `unboxedBitmaps`, `captureOffsets`,
     `crossEdges`. Prefer private globals (name-mangled with a stable
     hash) over stack allocas so repeated calls don't blow up the
     frame; deduplicate by content-hash if cheap.
   - Materialize `captures[]` and `outClosures[]` as stack allocas of
     i64 (these are call-local).
   - Emit safepoint marker once with `roots` using the same helper
     `PapCreateOpLowering` uses today.
   - Emit the single `LLVM::CallOp` to
     `eco_alloc_closure_group_slow`.
   - Load each `outClosures[i]` and `rewriter.replaceOp(op, results)`.

### Phase 4 — Elm frontend

10. **Add `Ops.ecoPapCreateGroup`** in
    `compiler/src/Compiler/Generate/MLIR/Ops.elm` — a builder that takes
    the flattened capture operand list, a per-sibling metadata list, and
    the cross-edge triples, and emits the single `eco.papCreateGroup`
    op with the attribute shape specified in step 1.

11. **SCC detection for let-chains** in
    `compiler/src/Compiler/Generate/MLIR/Expr.elm`:
    - Factor the capture-metadata computation out of the existing
      `MonoClosure` branch inside `generateExpr` (around the
      `eco.papCreate` emission at line 1131 and line 3875) into a
      reusable `analyseClosureBinding : Ctx -> Name -> MonoExpr ->
      Maybe ClosureBindingInfo`. This analyser must compute, for a
      prospective closure binding, the same data the current
      `papCreate` path computes: function symbol, arity, num_captured,
      unboxed_bitmap, ordered free-var list, and which free vars
      reference sibling placeholders.
    - In `generateLet` (line 3565), after
      `ctxWithPlaceholders`/`letBoundSiblings` are built (line 3600),
      walk the whole let-chain in a non-emitting pass, call
      `analyseClosureBinding` on each closure binding, and build a
      capture graph restricted to `boundNames`.
    - Compute SCCs (simple Tarjan / Kosaraju — treat self-loops
      separately since those stay on the existing self-capture path).

12. **Emit group ops for SCCs of size ≥ 2**:
    - For each such SCC:
      - Assign sibling indices (stable: e.g. sort by `Name`).
      - Build the flat non-sibling capture operand list and
        per-sibling `capture_indices` referencing it.
      - Build `cross_edges` from sibling-capture edges
        `(producer, consumer, slot)`.
      - Emit one `eco.papCreateGroup`; bind each result SSA var into
        `varMappings` for the corresponding name with type
        `Types.ecoValue`.
    - **Do not** run the per-binding RHS emission for group members;
      their RHS is replaced by the group op result. Skip them in the
      usual `MonoDef` chain walk.

13. **v1 constraint: closure-only SCCs in contiguous adjacent lets.**
    Group mode fires only when an SCC:
    - consists entirely of closure-valued bindings (i.e. RHS is
      `MonoClosure`), and
    - those bindings appear adjacently in the `MonoLet` chain.

    If either condition fails, assert + fall back to current behaviour
    for v1 (and cover the fallback with a test). Reordering /
    monomorphizer clustering is out of scope for v1.

14. **Keep existing paths for everything else**:
    - SCCs of size 1 (including those with a self-edge): keep the
      current `eco.papCreate` + `fixSelfCaptures` path unchanged.
      Group mode is restricted to SCCs of size ≥ 2 — true mutual
      recursion.
    - Non-closure bindings in the same let-chain: keep the current
      path; they see the new group result SSA vars in `varMappings`
      just like they see placeholder-bound vars today.
    - TailRec `compileLetStep` routes `MonoLet` through
      `Expr.generateExpr → Expr.generateLet`, so no TailRec-specific
      changes are needed — verify via a mutual tail-rec test.

15. **Sibling-capture slots must be boxed.** When building each
    sibling's metadata on the Elm side:
    - Place sibling-referenced captures into slots whose
      `unboxed_bitmap` bits are `00` and whose `_operand_types` entry
      is `!eco.value`.
    - Only non-sibling captures may be unboxed.
    - The op verifier (Phase 1 step 3) enforces this.

16. **Retire the placeholder trick for group members.** The
    placeholder installed by `addPlaceholderMappings` is replaced by
    the real group-op result SSA var. Do not run `fixSelfCaptures` on
    group-member `papCreate` ops (they no longer exist). It continues
    to run for non-group bindings.

### Phase 5 — Verification & tests

17. **CheckEcoClosureCaptures** pass: factor the per-sibling
    callee-shape check (num_captured vs callee arity, capture types)
    out of `papCreate` handling, then apply it to each sibling entry
    in `papCreateGroup`. This is the only place type/ABI consistency
    is verified; the op verifier only handles local structural
    invariants (Phase 1 step 3).

18. **MLIR round-trip test**: `test/codegen/pap_group.mlir` with a
    hand-written op exercising cross-edges, self-edges within a group
    (i.e. edge with `producer == consumer` when an SCC member captures
    itself alongside siblings), and non-sibling captures. FileCheck:
    - lowered LLVM contains exactly one
      `@eco_alloc_closure_group_slow` call and zero
      `@eco_alloc_closure_slow` calls for the block, and
    - after write-then-read through `mlir-opt` + MLIR bytecode, the op
      prints back identically (nested `ArrayAttr<DictionaryAttr>` and
      `ArrayAttr<ArrayAttr<I64>>` round-trip).

19. **Runtime unit test**: direct C++ test calling
    `eco_alloc_closure_group_slow` for the `evenP` / `oddP` pair; call
    each resulting closure and assert correct behaviour and correct
    sibling HPointer values.

20. **Elm regression**: resurrect / add the `evenP`/`oddP` mutual-let
    test and the GLSL parser `rassocP` / `rassocP1` case from the
    bootstrap; assert exactly one `eco.papCreateGroup` in the emitted
    MLIR and no dominance errors. Add a negative test confirming that
    a non-contiguous SCC (v1 constraint, decision 13) falls back
    cleanly.

21. **Full E2E**: `cmake --build build --target full` and the
    elm-test-rs suite (per CLAUDE.md). Walk the bootstrap stages.

### Phase 6 — Cleanup

22. Audit for other mutual-rec sites via
    `git grep MonoLet` and shape-match the pattern; confirm they route
    through the new path.
23. Remove any speculative `eco.closure.patch_capture` op / lowering
    if it was introduced locally (design doc says "if you had added
    it").

---

## Decisions (resolved)

1. **Runtime allocator API shape.** Match existing `_slow` naming and
   convention in `RuntimeExports.h`: no explicit `ThreadLocalHeap*`
   parameter; reach the allocator via `Allocator::instance()` just like
   `eco_alloc_closure_slow` (line 163/591) and `eco_gc_alloc_region_slow`
   (line 681). The group entry point is
   `eco_alloc_closure_group_slow` — signature locked in Phase 2 step 5.

2. **Contiguous reservation.** Use the existing region-allocator API:
   `eco_gc_alloc_region_fast(totalBytes)` → on null,
   `eco_gc_alloc_region_slow(totalBytes)`. These wrap
   `ThreadLocalHeap::allocateRegionSlow` and already provide
   "reserve N contiguous bytes atomically". No new nursery API needed.

3. **Large-object / pinned fallback.** `allocateRegionSlow` already
   routes large regions to `allocateLargePinned` (old-gen, pinned).
   The invariant is: one region call = one contiguous chunk in one
   generation. The group allocator **never splits across multiple
   region allocations** — siblings either all land in nursery or all
   in old-gen, never mixed.

4. **GC-roots partition.** `capturesCount = sum over siblings of
   capture_indices.size()`. `getGCRoots` returns the tail slice
   `operands[capturesCount..]`. This composes with `EcoGCPrepare`'s
   existing `papCreate` / `papExtend` convention (roots are appended
   after real operands, and the GCRootCarrier interface method reports
   the tail). Elm-side ensures the only non-root operands emitted are
   real capture values.

5. **Meaning of `num_captured`.** Single source of truth for
   `Closure.n_values`. For each sibling `i`:
   ```
   num_captured[i] == capture_indices[i].length
                    + count{ (p,c,slot) in cross_edges | c == i }
   ```
   Enforced by the op verifier.

6. **Unboxed bitmap for groups (v1).** Sibling-referenced capture
   slots are always boxed:
   - `_operand_types` entry = `!eco.value`.
   - `unboxed_bitmap` bit `2*slot` = 0 for any slot that appears as a
     cross-edge consumer slot.
   - Only non-sibling captures may be unboxed (Int / Float / Char via
     the existing `canUnbox` logic).
   - Verifier asserts the bitmap bit is clear for every cross-edge
     slot.

7. **Fast evaluator (`$cap`) clones.** No pipeline change: the
   existing compiler already emits the `$cap` clone for closures with
   captures and sets `_fast_evaluator` when building `papAttrs` for
   `eco.papCreate`. For groups, the same `_fast_evaluator` simply
   lives inside each sibling's dict in the `siblings` attribute and is
   threaded through `eco_alloc_closure_group_slow` just like
   `eco_alloc_closure_slow` uses it today.

8. **SCC size 1 (including self-edges).** Stays on the existing
   `fixSelfCaptures` path. Group mode fires only for SCCs of size ≥ 2.

9. **Mixed closure / non-closure bindings (v1).** Group mode requires
   that every SCC member be a closure-valued binding AND that the
   members appear adjacently in the `MonoLet` chain. If either
   condition fails, fall back to current behaviour (with a test
   covering the fallback). Reordering / monomorphizer clustering for
   interleaved SCCs is out of scope for v1.

10. **TailRec.** No TailRec-specific changes.
    `TailRec.compileLetStep` recomputes `boundNames` /
    `currentLetSiblings` via `Expr.addPlaceholderMappings` and dispatches
    `MonoLet` through `Expr.generateExpr → Expr.generateLet`, so any
    new group logic in `generateLet` applies automatically. Verified
    by a mutual-tail-rec test in Phase 5.

11. **Verifier placement.** Cross-edge slot-bounds and the
    `num_captured` relation live in `PapCreateGroupOp::verify`
    (cheap, attribute-only, O(#edges), fires without a pass).
    Type / ABI / callee-shape consistency lives in
    `CheckEcoClosureCaptures`, factored so `papCreate` and
    `papCreateGroup` share the per-sibling check.

12. **MLIR bytecode round-trip.** `ArrayAttr<DictionaryAttr>` and
    `ArrayAttr<ArrayAttr<I64>>` are already within what the eco
    dialect and MLIR bytecode encoder support. Phase 5 step 18
    includes a lit test that writes to bytecode, reads back with
    `mlir-opt`, and checks stable printing.

## Out of scope

- No GC algorithm changes (no write barrier, no generational
  promotion changes).
- No changes to call-site lowering (`papExtend`, `call`).
- Self-recursion continues to use the current `fixSelfCaptures` path.
- No changes to the `Closure` struct in `Heap.hpp`.
