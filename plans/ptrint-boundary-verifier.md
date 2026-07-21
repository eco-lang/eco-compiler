# ptr<1>↔i64 Boundary Refactor + Verifier

Tightens the ptr addrspace(1) ↔ i64 bridge in `EcoToLLVM*` so that:
1. Generic `valueToI64` / `i64ToValue` helpers are replaced by role-specific
   wrappers that encode the *allowed* boundary sites (heap/global/closure/args/
   case-scrutinee/wrapper).
2. A new post-RS4GC LLVM verifier pass, gated by `ECO_GC_DEBUG_LIVENESS`,
   rejects any `ptrtoint ptr<1>` / `inttoptr ptr<1>` that escapes the
   allow-listed patterns, closing the "HPtr → i64 → untracked → ptr<1>"
   loophole by construction *and* by enforcement.

## Invariants being tightened (tighter reading of REP_LLVM_001)

Extend `design_docs/invariants.csv` row `REP_LLVM_001` (and cross-reference from
`design_docs/theory/pass_eco_to_llvm_theory.md`):

- **REP_LLVM_PTR_ONLY_ACROSS_GC** — no `i64` derived from `ptrtoint ptr<1>` is
  live across a `gc.statepoint`.
- **INT→PTR provenance** — every `inttoptr i64 → ptr<1>` result either
  (a) has an operand loaded from a GC-scanned slot (heap field, global
  `eco.value`, closure `values[]`, or an args alloca registered via
  `eco_gc_push_stack_range`), or (b) is an embedded-constant pattern
  (`(kind << 40)` from `value_enc`).
- **Boundary restriction** — `ptrtoint`/`inttoptr` involving ptr<1> appears
  only at heap/global/closure storage boundaries, args arrays, ADT case/tag
  bit-manipulation, and embedded-constant encoding/decoding.
- **Single-use i64 from ptrtoint** — the i64 result of a `ptrtoint ptr<1>` is
  either stored into a slot, passed directly to a gc-leaf callee, or consumed
  by bit-tests in the same basic block; never reused across calls.

## Step-by-step plan

### Step 1 — Role-specific boundary helpers in `EcoToLLVMInternal.h`

File: `runtime/src/codegen/Passes/EcoToLLVMInternal.h`.

- Move the existing `valueToI64` / `i64ToValue` implementations into a nested
  `eco::detail::boundary::` namespace (or make them `static` inside a new
  `.cpp`). They stay as the underlying primitive but are no longer the
  public API.
- Add role-specific wrappers (all `inline`):
  - `heapStoreValueToI64(b, loc, v)` — heap field store.
  - `heapLoadI64ToValue(b, loc, v)` — heap field load.
  - `globalStoreValueToI64(b, loc, v)` / `globalLoadI64ToValue(b, loc, v)` —
    module-level `eco.value` globals (may alias `heap*` internally; distinct
    names to keep intent visible and to let the verifier key diagnostics).
  - `closureStoreValueToI64(b, loc, v)` / `closureLoadI64ToValue(b, loc, v)` —
    `Closure.values[]` slots.
  - `argsSlotStoreValueToI64(b, loc, v)` / `argsSlotLoadI64ToValue(b, loc, v)` —
    stack-allocated args buffers registered via `eco_gc_push_stack_range`.
  - `caseScrutineeToI64(b, loc, v)` — ADT case scrutinee for tag bit-tests
    (result must stay inside the same basic block, no calls).
  - `wrapperReturnValueToPtr0(b, loc, v, retPtrTy)` — evaluator-wrapper return
    bridging: ptr<1> → i64 → ptr AS0.
  - `wrapperLoadArgSlotToValue(b, loc, loadOp, targetType)` — wrapper arg
    unboxing (load i64 from wrapper args alloca, convert to ptr<1> / unboxed
    primitive / typed ptr as needed).
- Keep comments next to each helper describing the *single* pattern they
  authorize; future reviewers should not reach for the raw primitives.

### Step 2 — Call-site rewrites in `EcoToLLVMHeap.cpp`

File: `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`.

- `widenFieldToI64` (around lines 443–456): change its body to call
  `heapStoreValueToI64` and add a doc-comment contract: caller must consume
  the result *immediately* in a store / leaf-call argument.
- Construct lowerings (List/Cons, Tuple2/Tuple3, Record, Custom): verify the
  result of `widenFieldToI64` has exactly one use (a `LLVM::StoreOp` or a
  `LLVM::CallOp` argument to an `eco_init_*_at` / `eco_alloc_cons` / etc.).
- Project lowerings (ListHead/Tail, Tuple/Record/Custom/Array): replace
  `i64ToValue` after `LoadOp i64` with `heapLoadI64ToValue`. Keep the exact
  "load → helper → use" shape so the verifier can pattern-match.
- `widenToI64ForInit` / `castToI64` / `castToHPtr` (alloc-group paths):
  - Leave structurally unchanged (they operate on pre-reconcile IR and use
    `UnrealizedConversionCastOp`).
  - Add a block comment explicitly calling out that results are immediately
    stored into alloc-group region slots and never leave the group region.
  - Tag their call sites with a distinctive comment string that the verifier
    can also recognise (e.g. a named helper or a `discardable` attr on the
    op) — see Step 5 (verifier) for how we use this.

### Step 3 — Call-site rewrites in `EcoToLLVMGlobals.cpp`

File: `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp`.

- Replace `valueToI64` (line ~96) at the global-store site with
  `globalStoreValueToI64`; ensure its result is used only by the following
  `LLVM::StoreOp` into the global.
- Replace `i64ToValue` (line ~70) at the global-load site with
  `globalLoadI64ToValue`; ensure it is produced directly from a `LoadOp` on
  the global address.

### Step 4 — Call-site rewrites in `EcoToLLVMControlFlow.cpp`

File: `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`.

- Replace `valueToI64` in the ADT-case scrutinee lowering with
  `caseScrutineeToI64`.
- Confirm statically (code-reading pass) that the bit-ops following the helper
  (`LShr(40)`, `And(0xF)`, `ICmp`) live in the same basic block and no call
  is emitted between the `ptrtoint` and the `ICmp`.
- String-case True comparison already uses ptr-equality via `inttoptr i64
  const`; leave unchanged but annotate it as the "embedded-constant encoding"
  allowed pattern (see Step 5 verifier constant recogniser).

### Step 5 — Call-site rewrites in `EcoToLLVMClosures.cpp`

File: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`.

- `PapCreateOp` lowering (captures, including the self-capture path):
  replace the direct `LLVM::PtrToIntOp` (~line 640) and `valueToI64`
  (~line 652) with `closureStoreValueToI64`. Ensure the result has exactly
  one use: the `LLVM::StoreOp` into `Closure.values[i]`.
- `ProjectClosureOp` lowering:
  - Boxed target: `LoadOp i64` → `closureLoadI64ToValue`.
  - Pointer target (typed ptr, not ptr<1>): `LoadOp i64` → direct
    `LLVM::IntToPtrOp` on the load result (operand must be the `LoadOp`).
  - Primitive target: load + bitcast/trunc as today.
- `emitRootedBoxedArgsArray` (line ~91): rewrite the per-arg store loop to
  use `argsSlotStoreValueToI64`, and assert locally that each `ptrtoint`
  result has exactly one use (the `LLVM::StoreOp` into the alloca slot).
- `lowerSegmentationUnknown` (line ~1109) and `lowerGenericApply` (line
  ~1193): same treatment for both boxed and typed argument arrays; the typed
  path continues to rely on `unboxed_bitmap` to mark which slots are
  primitive vs HPtr.
- `getOrCreateWrapper` (line ~280):
  - Arg-unboxing loop: replace hand-rolled `i64ToValue` / `IntToPtrOp` calls
    with `wrapperLoadArgSlotToValue`. The helper receives the `LoadOp` and
    the target LLVM type, and chooses the right conversion.
  - Return bridging: use `wrapperReturnValueToPtr0`, which implements the
    exact `ptr<1> → i64 → ptr AS0` sequence the outer ABI requires.

### Step 6 — New LLVM verifier pass `EcoPtrIntVerify`

Files:
- New: `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp` (plus a small
  `runtime/src/codegen/Passes/EcoPtrIntVerify.h` exporting
  `createEcoPtrIntVerifyPass()`).
- Modified: `runtime/src/codegen/CMakeLists.txt` (add the new source to
  `obj.EcoPasses`).
- Modified: `runtime/src/codegen/Passes/EcoGCStrategy.cpp` (or a companion
  translation unit next to it): add a single **central registration helper**
  `eco::addEcoGCPipeline(llvm::ModulePassManager &MPM)` that (a) adds
  `RewriteStatepointsForGC`, and (b) under `#ifdef ECO_GC_DEBUG_LIVENESS`
  additionally adds `EcoPtrIntVerify` *after* RS4GC.
- Modified: `runtime/src/codegen/EcoRunner.cpp`, `runtime/src/codegen/ecoc.cpp`,
  `runtime/src/codegen/eco-boot.cpp` — each currently constructs a
  `ModulePassManager` and calls `MPM.addPass(llvm::RewriteStatepointsForGC());`
  directly (three copies total: `EcoRunner.cpp:210`, `ecoc.cpp:216`,
  `ecoc.cpp:298`, `eco-boot.cpp:629`). Replace each with a call to
  `eco::addEcoGCPipeline(MPM)` so the verifier is always added alongside RS4GC
  and no site can drift out of sync.

Pass design (LLVM FunctionPass iterated over all functions of a module, or
ModulePass):

- Identify `ptr<1>` via `PointerType::getAddressSpace() == 1` (matches
  `isHPtrLLVMType`).
- **Args-alloca discovery (per function):** before checking ptrtoint/inttoptr
  uses, build a small `DenseSet<AllocaInst*> gcArgsAllocas`:
  - Scan the function for calls to `@eco_gc_push_stack_range`.
  - Walk each pointer-operand through trivial `bitcast`/`addrspacecast`/GEP
    chains back to its underlying value; if the base is an `AllocaInst`, add
    it to the set.
  - No new MLIR-level marker / metadata is required — recognition lives
    entirely in the verifier.
- **Gc-leaf recognition:** a callee is considered gc-leaf if its LLVM
  function has the `"gc-leaf-function"` attribute. This matches the set
  already consulted by RS4GC / `EcoGCStrategy`; no separate whitelist is
  maintained in the verifier. Indirect calls are treated as non-leaf.
- For each `PtrToIntInst` whose source operand is ptr<1>:
  - Walk uses through trivial `zext`/`trunc`/`bitcast` in the same basic
    block (reject otherwise).
  - Accept the use if it is:
    1. A `StoreInst` into a GEP on a recognised heap/global/closure struct,
       or into an alloca that is in `gcArgsAllocas`. Heap/global/closure
       recognition matches struct-type names emitted by our lowering
       (`%eco.Closure`, `%eco.Cons`, `%eco.Record`, `%eco.Tuple*`,
       `%eco.Custom`, `%eco.Array`, `%eco.String`) and globals whose type
       is `ptr addrspace(1)` / `i64` backing an `eco.value` slot.
    2. A `CallInst` whose callee has the `"gc-leaf-function"` attribute
       (and the i64 is a value parameter, not a pointer parameter that
       should have stayed ptr<1>).
    3. An ADT tag bit-test chain — `lshr`, `and`, `icmp eq` — fully within
       the same basic block, ending at an `icmp` whose result feeds control
       flow only.
  - Otherwise `report_fatal_error(...)`:
    `EcoPtrIntVerify: ptrtoint ptr addrspace(1) result escapes allowed
    patterns in function <F> at <I>; may be live across GC.`
- For each `IntToPtrInst` whose result is ptr<1>:
  - Accept if the operand is:
    1. A `LoadInst` from a GEP into a recognised heap/global/closure struct,
       or from an alloca in `gcArgsAllocas`.
    2. An integer constant matching `value_enc::encodeConstant(kind)`
       — imported directly from `EcoToLLVMInternal.h` so the set stays in
       sync with `HPointer::ConstantKind` (Unit, EmptyRec, True, False, Nil,
       Nothing, EmptyString).
    3. A PHI whose every incoming value satisfies (1) or (2). Start strict:
       reject unknown PHI inputs; relax only if a real fixture requires it.
  - Otherwise `report_fatal_error(...)`:
    `EcoPtrIntVerify: inttoptr i64 -> ptr addrspace(1) from non-heap/non-args
    source in <F> at <I>.`
- **Diagnostic severity:** hard error via `llvm::report_fatal_error`.
  `ECO_GC_DEBUG_LIVENESS` is already a slow debug-only verification mode,
  so failing fast gives reproducible stack traces instead of warnings that
  can be missed. No warning mode initially.
- **Residual UnrealizedConversionCast sanity check (debug assertion only):**
  alloc-group casts (`widenToI64ForInit`, `castToI64`, `castToHPtr`) run
  pre-`ReconcileUnrealizedCasts` and are structurally gone by the time
  MLIR→LLVM translation and RS4GC have run. Add a debug-only assertion that
  scans for any LLVM IR pattern resembling a leftover `UnrealizedConversion`
  (e.g. an untyped copy instruction with our marker) and fails loudly if
  found. In normal builds the assertion is a no-op.
- **Implementation notes:**
  - The entire pass body is under `#ifdef ECO_GC_DEBUG_LIVENESS`. In Release
    builds, `createEcoPtrIntVerifyPass()` returns `nullptr` and
    `addEcoGCPipeline` skips the add-call via the same `#ifdef`.
  - Reuse any helpers from `EcoGCLivenessAudit.cpp` for struct-type
    recognition if they're present; otherwise copy minimal predicates.

### Step 7 — Tests

- `runtime/test/codegen/` MLIR/LLVM lit tests (check where existing
  `safepoint_statepoint_emission.mlir` and related files live; mirror that
  directory). Add:
  - `ptrint_verify_pass.mlir` — good cases: heap store/load, closure capture,
    ADT case scrutinee, global load/store, args array populate, wrapper
    return bridging, embedded-constant True pattern. Pipe through
    `ecoc --emit-llvm-after-rs4gc --verify-ptrint` (or an equivalent harness
    flag; see open questions). Expect zero diagnostics.
  - `ptrint_verify_pass_bad.mlir` — synthesised LLVM IR that:
    - puts a `ptrtoint ptr addrspace(1)` result into a call to a non-leaf
      callee (must fail);
    - does `inttoptr i64 <arbitrary>` to ptr<1> with a non-load operand
      (must fail).
  - Reuse / extend `safepoint_statepoint_emission.mlir` to exercise at least
    one full alloc → store-to-field → project round-trip so the verifier
    runs against realistic IR.
- Elm/E2E smoke test: enable the build preset with
  `-DECO_GC_DEBUG_LIVENESS=ON`, run `cmake --build build --target full`, and
  confirm no diagnostics on any in-tree test fixture.
- Add a regression fixture for the Stage-7 reproducer: drop a minimal MLIR
  that used to produce an escaping ptrtoint (see the original audit), lower
  it, and check that the verifier flags it.

### Step 8 — Documentation

- `design_docs/invariants.csv`: extend the text of `REP_LLVM_001` with the
  four sub-invariants above; add a Source column pointer to
  `EcoPtrIntVerify.cpp`.
- `design_docs/theory/pass_eco_to_llvm_theory.md`: add a subsection
  "ptr<1>↔i64 boundary" summarising the allowed patterns and the helper
  table; link to the verifier.
- `guides/gc-diagnostics.md`: document `EcoPtrIntVerify` alongside
  `EcoGCLivenessAudit`, noting that it is post-RS4GC LLVM-level whereas the
  audit is pre-RS4GC MLIR-level.

### Step 9 — Rollout / sequencing

1. Land Step 1 and Step 2–5 in a single PR, with no functional change
   (helpers are still thin wrappers). This gives reviewers diffs that show
   intent clearly.
2. Land Step 6 (verifier) behind `ECO_GC_DEBUG_LIVENESS` in a second PR. CI
   should run one build-preset with the flag ON so new violations are caught
   at review time.
3. Land tests (Step 7) and doc updates (Step 8) alongside or just after
   Step 6.

## Files touched (summary)

| File | Change |
| --- | --- |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Add role-specific helpers; demote old ones to `detail::`. |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | Re-point construct/project helpers; annotate alloc-group casts. |
| `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp` | Use `globalStore/Load` helpers. |
| `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` | Use `caseScrutineeToI64`. |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Use closure/args/wrapper helpers across PapCreate, ProjectClosure, `emitRootedBoxedArgsArray`, SegUnknown, GenericApply, wrapper. |
| `runtime/src/codegen/Passes/EcoPtrIntVerify.{h,cpp}` | New verifier pass. |
| `runtime/src/codegen/Passes/EcoGCStrategy.cpp` | Add `addEcoGCPipeline(MPM)` helper that wires RS4GC + verifier. |
| `runtime/src/codegen/CMakeLists.txt` | Add `Passes/EcoPtrIntVerify.cpp` to `obj.EcoPasses`. |
| `runtime/src/codegen/EcoRunner.cpp` | Replace direct `RewriteStatepointsForGC` add with `addEcoGCPipeline`. |
| `runtime/src/codegen/ecoc.cpp` | Same (two RS4GC call sites). |
| `runtime/src/codegen/eco-boot.cpp` | Same. |
| `design_docs/invariants.csv` | Extend `REP_LLVM_001`. |
| `design_docs/theory/pass_eco_to_llvm_theory.md` | New "boundary" subsection. |
| `guides/gc-diagnostics.md` | Document verifier. |
| `runtime/test/codegen/ptrint_verify_pass*.mlir` | New tests. |

## Resolved decisions

1. **Central verifier registration.** A new helper
   `eco::addEcoGCPipeline(llvm::ModulePassManager &MPM)` lives alongside
   `EcoGCStrategy.cpp`. It adds `RewriteStatepointsForGC` and, under
   `#ifdef ECO_GC_DEBUG_LIVENESS`, `EcoPtrIntVerify` immediately after.
   `EcoRunner.cpp`, `ecoc.cpp` (both call sites), and `eco-boot.cpp` all
   switch to calling this helper so the verifier can't drift out of sync
   with RS4GC.

2. **Gc-leaf recognition.** Reuse the existing mechanism: a callee is leaf
   iff its LLVM function has the `"gc-leaf-function"` attribute (same set
   RS4GC / `EcoGCStrategy` already consult). No separate whitelist. Indirect
   calls are treated as non-leaf.

3. **Args-alloca recognition.** Pure IR discovery, no new marker. For each
   function the verifier scans calls to `@eco_gc_push_stack_range`, walks
   the pointer operand through trivial `bitcast`/`addrspacecast`/GEP back
   to its underlying `AllocaInst`, and records that alloca as a
   GC-tracked args buffer. Can be revisited later if optimisation breaks
   the def-chain; until then no metadata is emitted.

4. **Alloc-group `UnrealizedConversionCastOp`.** By design, these are gone
   by the time the verifier runs. `ReconcileUnrealizedCasts` cancels them
   before MLIR→LLVM translation (documented in the EcoToLLVM theory doc),
   and RS4GC operates strictly on LLVM IR. A debug-only assertion in the
   verifier guards against regressions; it is a no-op in release builds.

5. **Constant-encoding recogniser.** The verifier imports the constants
   directly from `EcoToLLVMInternal.h` (`value_enc::encodeConstant`,
   `ConstFieldShift`, `ConstFieldMask`, and the `ConstantKind` enum) so
   there is a single source of truth shared with the lowering code.

6. **Wrapper return bridging is the only GC-world → AS0 exit for HPointers.**
   The raw ptrtoint in `BFToLLVM.cpp:1002` is a ByteFusion cursor (plain
   AS0 pointer, not ptr<1>) and never returns to ptr<1>, so it is out of
   scope. Any future C-ABI shim that returns an Elm value as
   `void*`/AS0 must funnel through `wrapperReturnValueToPtr0` (or a sibling
   helper) to stay allow-listed.

7. **Diagnostic severity.** Violations are hard errors — the pass calls
   `llvm::report_fatal_error` on the first bad instruction. This matches
   `EcoGCLivenessAudit`'s "slow, debug-only, fail-fast" posture and keeps
   the signal high in CI.

8. **No shared context object for helpers.** `wrapperLoadArgSlotToValue`
   and friends stay as `inline` helpers parameterised on the target LLVM
   type supplied by the caller. No type-converter or context plumbing is
   introduced.

9. **Backward-compat for `valueToI64` / `i64ToValue`.** `EcoToLLVMInternal.h`
   is explicitly "NOT part of the public API", and the only in-tree
   consumers are the EcoToLLVM* files rewritten in Steps 2–5. Moving the
   primitives under `detail::` is safe; no installed headers or external
   libraries depend on them.

---

## ADDENDUM (2026-07-21): the fold gap and its closure (REP_LLVM_002)

A KNOWN GAP in this verifier was found during E1.3 v1/v2
(`plans/lss-dispatch-value-extraction.md` §E1.6): it CANNOT see the folded
form. When `InlineFunction`'s SimplifyInstruction annihilates a
`ptrtoint(inttoptr(x)) → x` pair across an inlining seam, the resulting raw
i64 that is live across statepoints comes straight from a load — the
`ptrtoint` predicate (a) keys on is ERASED, and the load satisfies the (b)
provenance allowance. Both bisected miscompiles of that era lowered CLEAN
through this verifier.

CLOSED by `plans/fold-proof-boxed-slot-crossings.md` (E1.3 v3, REP_LLVM_002):
boxed-slot crossings are now emitted as opaque gc-leaf barrier calls
(`__eco_slot_to_hptr`/`__eco_hptr_to_slot`) that no inliner can fold, so the
folded form CANNOT EXIST pre-RS4GC. `StripEcoCastBarriers` — which lives in
this pass's own file and runs in `addEcoGCPipeline` between RS4GC and this
verifier — restores the bare casts, so THIS VERIFIER CONTINUES TO CHECK
EXACTLY THE SHAPES DOCUMENTED ABOVE (the restored casts), unchanged. The
verifier's role is now genuinely complete: emission-side fold-proofing
prevents the class it cannot see, and it still checks everything it can see.
Verified 2026-07-21: an ECO_LOWERING_VALIDATION build lowered the full
all-keyed self-compile module with 15,744 `$cap` bodies force-inlined
(GC-bearing included) — silent.
