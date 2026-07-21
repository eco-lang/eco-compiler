# Fold-proof boxed-slot crossings (E1.3 v3): unlock `$cap` inlining for real

**Status: IMPLEMENTED + GATED (2026-07-21). V3.0-V3.3 SHIPPED; §9 records the
as-built results.** Headline: barriers are byte-transparent (60 MB all-keyed
binary lowered barriers-on vs barriers-off is BYTE-IDENTICAL; +2.7 % lowering
wall), the guard is LIFTED (15,744 `$cap` bodies marked vs the previous 257
— the plan's ~15.7 K prediction), surviving direct `$cap` calls 11,294 →
5,161 (the predicted ≈5.2 K mismatched-ABI residue), and the all-keyed
Stage-7a self-compile under the FULL lift runs rc=0 with output
byte-identical to the un-inlined leg (the configuration that crashed v1/v2
variants in 1-4 s). Full corpus 1628/1628.

Successor to the E1.3 v1/v2 work recorded in
`plans/lss-dispatch-value-extraction.md` §5/E1.6. Prerequisite knowledge: both
bisected miscompile classes and the verifier gap documented there — read that
section first; this plan does not restate the full anatomy. A line-level
validation pass (§7) verified every load-bearing premise against the code and
corrected three structural details (strip placement, helper-funnel staleness,
emission mechanics); §8 carries the V3.0 audit table (confirmed as-built).

**Goal:** make every i64⇄`ptr addrspace(1)` boxed-slot crossing immune to the
inliner's `ptrtoint(inttoptr(x)) → x` fold, so `runCapInlinePrepass`
(EcoBackend.cpp) can drop the `bodyIsGCCallFree` guard and inline the full
small-`$cap` population (~15.7 K bodies / ~6.4 K call sites at the all-keyed
self-compile; today's sound population is 257 call-free bodies) — the E1
payoff at Run M's 99.6 M fast calls/run.

---

## 1. The hazard being engineered away (2-sentence recap)

Boxed heap/args/closure slots are read as `load i64` + `inttoptr → ptr<1>`
and written as `ptrtoint` + `store i64`. Standalone bodies keep the tracked
`ptr<1>` hop (nothing simplifies pre-RS4GC), but `InlineFunction`'s
SimplifyInstruction folds producer/consumer pairs met across an inlining seam
— the raw i64 then crosses the spliced body's statepoints invisible to RS4GC
and goes stale on GC. Two bisected instances: capture unpacking
(`lambda_15194$cap`, fixed by the v2 typed capture loads) and tuple-projection
→ args-slot store (`lambda_14615$cap`, open — the general interior case).
`EcoPtrIntVerify` cannot flag the folded form (the fold erases the `ptrtoint`
its (a)-predicate keys on).

## 2. Design: opaque cast barriers at the helper layer (Option B),
## typed loads kept where already landed (v2)

Two candidate shapes were considered:

- **A — typed slots everywhere:** every boxed-slot load/store emitted at
  `ptr addrspace(1)` directly. Strictly the cleaner REP model, but a
  migration across EVERY heap/args/closure lowering (EcoToLLVMHeap.cpp
  projections + construct/to_heap stores, args buffers, closure stores…),
  each site needing its boxedness statically threaded. Large blast radius in
  the most dangerous code region we have.
- **B — opaque cast barriers (CHOSEN):** the crossings already funnel through
  a small helper layer — `EcoToLLVMInternal.h:54-164` (anchor corrected;
  see §7.2 for the verified live-funnel inventory: `heapLoadI64ToValue`,
  `heapStoreValueToI64`, `globalLoadI64ToValue`, `globalStoreValueToI64`,
  `closureStoreValueToI64`, `argsSlotStoreValueToI64`,
  `wrapperLoadArgSlotToValue`'s ptr<1> branch, plus the underlying
  `i64ToValue`/`valueToI64`; NOTE `closureLoadI64ToValue` and
  `argsSlotLoadI64ToValue` currently have ZERO callers — v2's typed loads
  took the closure-load path, and the one live args-slot-load idiom is a raw
  cast straggler, §8). Emit those crossings as calls to two
  DECLARE-ONLY, `gc-leaf-function` LLVM functions instead of casts:

      declare ptr addrspace(1) @__eco_slot_to_hptr(i64)
      declare i64 @__eco_hptr_to_slot(ptr addrspace(1))

  The inliner cannot fold through an opaque call, so the tracked `ptr<1>`
  hop SURVIVES inlining; RS4GC sees a gc-leaf call (no statepoint) whose
  `ptr<1>` result/arg is ordinary tracked SSA — relocation is exactly the
  standalone-body semantics. A tiny post-RS4GC strip pass then rewrites
  every barrier call back to the bare `inttoptr`/`ptrtoint`, so codegen and
  the per-partition -O2 see exactly today's IR. Zero runtime cost, zero
  symbol footprint (stripped before emission), future-proof: any NEW
  crossing routed through the helpers is protected automatically.

v2's typed capture loads STAY (typed is strictly better than a barrier where
the slot's boxedness is statically known at the load site); barriers cover
everything else, including consumers (stores), which typed loads cannot.

### 2.1 Barrier emission

- In `EcoToLLVMInternal.h`, `i64ToValue`/`valueToI64` gain a barrier-emitting
  form used by the SLOT-crossing wrappers only (the live-funnel list in §7.2:
  heap/global/closure/argsSlot load+store roles plus
  `wrapperLoadArgSlotToValue`'s ptr<1> branch). NOT converted:
  embedded-constant encode/decode, ADT tag/bit-manipulation crossings
  (REP_LLVM_001(c) classes with no slot provenance — they never carry
  relocatable pointers), the AS0 wrapper-ABI exits
  (`wrapperReturnValueToPtr0`), and the shadow-root frame (§7.5).
- The audit milestone (V3.0) also finds RAW `LLVM::IntToPtrOp`/`PtrToIntOp`
  emissions in `Passes/*.cpp` that bypass the helpers (at least one existed
  in `emitFastClosureCall` before v2) and routes slot-crossing ones through
  the helpers.

### 2.2 Strip pass and placement

`StripEcoCastBarriers` (LLVM ModulePass, ~40 lines): for each call to a
barrier symbol, `replaceAllUsesWith` an adjacent cast built at the call site;
erase the call; then verify the module contains ZERO barrier references and
erase the declarations. The zero-survivors check MUST be
`report_fatal_error`, NOT `assert` — asserts vanish under NDEBUG and "hard
error, not silent perf loss" has to hold on the shipping config.

Placement (CORRECTED by the §7 validation — the original "three placements"
undercounted): `runRS4GCAndMaybeFramePointers` has FIVE call sites in
EcoBackend.cpp (serial `:946`, deferred `:971`, split-worker `:282`,
lazy-split-worker `:513`, single-partition fallback `:1035`) and no callers
outside that file. Instead of chasing call sites, add the strip pass INSIDE
`addEcoGCPipeline` (EcoPtrIntVerify.cpp:447) directly after
`RewriteStatepointsForGC()` and BEFORE `EcoPtrIntVerifyPass`. One insertion
then covers all five RS4GC runs plus the JIT and DumpLLVMText paths (both
route through the serial run), the `--dump-post-rs4gc-ir` dump
(EcoBackend.cpp:642, which runs after the MPM) shows STRIPPED IR — directly
diffable against today's — and, crucially, `EcoPtrIntVerify` verifies the
RESTORED casts, so the validation build keeps checking exactly the IR shape
it checks today (the verifier-gap closure becomes real rather than vacuous).
Pre-RS4GC dumps (`--dump-pre-rs4gc-ir`) show the barriers — desired for
debugging. Implement the pass in EcoPtrIntVerify.cpp next to
`FoldExtractValuePass` (same file already hosts the pipeline helper), and
NOT behind `#ifdef ECO_LOWERING_VALIDATION` — it is functional, not
diagnostic. The pass must be a cheap no-op when the two symbols are absent
(mirrors `expandInlineDerefs`' idempotence), so it needs no env gating.

### 2.2.1 Emission mechanics (settled by the §7 validation)

- **Decls:** two new `EcoRuntime::getOrCreate*` functions using the existing
  `getOrCreateFunc(..., gcLeaf=true)` passthrough mechanism
  (EcoToLLVMRuntime.cpp:142-149), REGISTERED IN `materializeAllRuntimeDecls`
  (EcoToLLVMRuntime.cpp:1110) — the H4.2 parallel-freeze gotcha: any decl a
  Stage-2 body pattern demands must be pre-created or the frozen-cache
  assert fires. Pre-materialization is unconditional (EcoToLLVM.cpp:305), so
  the decls exist on every path (AOT, JIT, codegen tests).
- **The header helpers need NO EcoRuntime plumbing:** the vendored LLVM
  21.1.8 MLIR has `LLVM::CallOp::build(builder, state, TypeRange results,
  StringRef callee, ValueRange args)` — the helpers emit barrier calls by
  symbol name; MLIR verification resolves them against the pre-materialized
  decls. This matters because `populateEcoGlobalPatterns` has no `runtime`
  parameter — by-name emission avoids widening any populate/helper
  signatures.
- **Env-off byte-identity is free:** the unused-decl strip
  (EcoToLLVM.cpp:529-549) erases the two unreferenced barrier decls when the
  env is off, restoring today's exact symbol set.
- **Decl attributes: exactly `gc-leaf-function` (+ optionally `nounwind`).**
  Do NOT add `memory(none)`/`readnone`/`speculatable`: motion-enabling
  attributes would license a future pre-RS4GC pass to hoist/sink a barrier
  call across a statepoint — resurrecting the raw-i64 crossing the barrier
  exists to prevent. Record this constraint in a comment at the decl site.
- **Pass-through parity:** the barrier form must emit a call ONLY where the
  cast form emits a cast (identical type conditions in
  `i64ToValue`/`valueToI64`), so the pre-RS4GC IR is a strict 1:1
  cast→call swap — same instruction count, same positions. This keeps
  `bodyIsGCCallFree` (barrier calls are gc-leaf → skipped) and the
  `getInstructionCount` threshold env-invariant, so the v1 257-body marking
  set cannot shift while the guard is still on (V3.1/V3.2 gate below).
- **Env read:** one `static const bool` (magic static, ODR-shared, safe
  under parallel Stage 2) in a header-level `slotCastBarriersEnabled()`.

### 2.3 Interaction notes (verified reasoning, to re-verify in V3.4)

- GC-registered args buffers (`eco_gc_push_stack_range` over i64 allocas):
  barrier output stored into the slot is the same 8 bytes; the runtime's
  slot relocation is unchanged. SSA-side, the barrier keeps the value
  `ptr<1>` until the store — RS4GC liveness handles any statepoint between.
- The wrapper gc-live root-alloca protocol (`getOrCreateWrapper`) is
  untouched — it operates on its own i64 copies.
- `AlwaysInlinerPass` inlines bodies CONTAINING barrier calls fine (calls are
  ordinary instructions); the barriers are why that is now safe.
- JIT path (`-emit=jit`) runs the same backend — SETTLED (§7.7): JIT and
  DumpLLVMText both take the serial RS4GC branch, so the §2.2 placement
  covers them by construction.

## 3. Milestones

- **V3.0 — crossing audit (confirm §8, no behavior change).** The §7
  validation pass already enumerated every `IntToPtrOp`/`PtrToIntOp`
  emission in `runtime/src/codegen/Passes/` (26 sites; ZERO outside
  `Passes/` — grep-verified) + every helper caller (33 sites) and drafted
  the classification table (§8). V3.0 = re-verify each §8 row at
  implementation time (line anchors drift) and resolve the two rows marked
  `AUDIT`. Gate: none (read-only).
- **V3.1 — barrier infra + wrapper routing.** Barrier decls (§2.2.1) +
  barrier-emitting forms in `EcoToLLVMInternal.h` + ROUTE THE LIVE
  SLOT-CROSSING WRAPPERS (§7.2 list) — without the routing this milestone's
  gate would exercise zero barriers (the original plan deferred routing to
  V3.2, leaving V3.1's zero-delta gate vacuous — corrected);
  `StripEcoCastBarriers` in `addEcoGCPipeline` (§2.2 corrected placement) +
  the zero-references fatal check. Emit barriers ONLY under a new env
  `ECO_SLOT_CAST_BARRIERS=1` initially (default off = byte-identical output
  via the unused-decl strip; flip to default-on in V3.3). Gate: codegen
  suite green both env states; with the env on, whole-binary objdump diff
  vs baseline = ZERO code delta (strip restores today's IR exactly; if the
  binary diff trips, diff the `--dump-post-rs4gc-ir` text first — it is
  stripped and directly comparable — to localize before suspecting
  codegen); `ECO_CAP_INLINE_DEBUG` marked-set listing IDENTICAL env-on vs
  env-off (the 257-body population must not shift — §2.2.1 parity).
- **V3.2 — stragglers + AS-aware routing.** Raw-cast stragglers from §8
  routed through the helpers. Two need care: `EcoToLLVMClosures.cpp:2199`
  converts BOTH AS0 and AS1 pointers — only the AS1 arm may route through
  `argsSlotStoreValueToI64` (the helper passes AS0 through unchanged, which
  would type-error the i64 store); and the alloc-group family
  (`castToHPtr`/`widenToI64ForInit`/`castToI64`) classifies per §8. Gate:
  same as V3.1 + all-keyed self-compile green env-on (guard still ON —
  barriers must be inert-correct before the lift) + lowering-wall
  measurement vs the ≤+10% budget (§6.1).
- **V3.3 — the lift.** Barriers default-on; `bodyIsGCCallFree` guard removed
  from the default marking condition (`ECO_CAP_INLINE_GCFREE_ONLY`-style env
  retained for A/B); delete `ECO_CAP_INLINE_NO_GCFREE_GUARD`
  (EcoBackend.cpp:854-855). **Coupling constraint (new):** once the guard is
  gone, `ECO_SLOT_CAST_BARRIERS=0` + full-population inlining is a KNOWN
  UNSOUND combination — the off state must force the GC-call-free guard back
  ON (one condition in `runCapInlinePrepass`), so no env combination
  reconstructs the miscompile. Gate: the FULL battery (§4). This is the
  milestone both bisected culprits attack directly: `ECO_CAP_INLINE_LIST`
  with only `lambda_14615$cap` (this generation's) marked MUST run green
  before the full population does.
- **V3.4 — battery + Run O.** §4 battery; then the Run-N-style interleaved
  wall A/B ×3 + census sanity (counts must be identical; fast counters are
  call-site-side), objdump surviving-call count (expect ≈5.2 K → the
  mismatched-ABI + oversized residue only), binary size, and the NOW
  meaningful `ECO_CAP_INLINE_MAX_INSTS` sweep (64/128/256). Write Run O into
  `benchmarks/runtime-calls.md`; update plan §5/E1.6 + memory.

## 4. Validation battery (the standing discipline for this code region)

1. Codegen suite (`TEST_FILTER=codegen`) + full corpus (`--target check`) —
   necessary, NOT sufficient (both bisected classes were corpus-invisible).
2. **All-keyed self-compile repro** (`ECO_MONO_ENGINE=solver` +keyed default)
   — THE gate: rc=0 AND output byte-identical to the un-inlined leg.
3. Single-culprit pre-gates: `ECO_CAP_INLINE_LIST` legs for the two known
   culprit shapes before the full-population leg (fast, ~10 s to crash when
   wrong).
4. `EcoPtrIntVerify` (ECO_LOWERING_VALIDATION build, a COMPILE-TIME CMake
   option): silent on the shipping config. Known gap: it cannot see the
   folded form — with barriers the folded form cannot exist, which is the
   real closure of the gap; note it in `ptrint-boundary-verifier.md`.
5. `ECO_HEAP_VALIDATE` leg (also compile-time; ~40-45× wall — budget it: a
   BOUNDED workload, e.g. a mid-sized package compile, not the full
   self-compile; the full-leg attempt on 2026-07-21 ran 3.5 h clean before
   being killed as diminishing-returns).
6. Debug arsenal on any failure: threshold/list bisection driver (session
   pattern, two prior successes at ~14 lowerings each), `--dump-pre-rs4gc-ir`
   + function extraction, bpftrace (sudo + tracefs) for runtime localization,
   `ECO_HEAP_CONFIG` tiny-nursery to force early GC.

## 5. Invariants delta

- **REP_LLVM_002 (new):** every i64⇄`ptr addrspace(1)` crossing with
  boxed-slot provenance is emitted fold-proof (typed load/store or an
  `__eco_slot_to_hptr`/`__eco_hptr_to_slot` barrier) until RS4GC has run;
  `StripEcoCastBarriers` restores bare casts strictly post-RS4GC (before
  `EcoPtrIntVerify`, which therefore verifies the restored casts) and
  hard-fails (`report_fatal_error`, active in release) if any barrier
  survives to codegen. Rationale: REP_LLVM_001(a) is not fold-stable —
  `ptrtoint(inttoptr(x)) → x` erases the evidence the invariant's verifier
  keys on; the sharpened hazard model behind the wording is §7.6.
- REP_LLVM_001 unchanged in force; add a cross-reference row.

## 6. Risks / open questions

1. Barrier-call volume: millions of crossings → pre-RS4GC IR growth (a call
   is 1 instruction like the cast, but heavier in memory + symbol-ref attr)
   and RS4GC/strip walk cost — measure lowering wall in V3.2 (budget:
   ≤ +10 % backend wall; the 2026-07-21 lowerings ran ~60-90 s).
   **Mitigation lever if the budget trips (§7.6):** the producer side
   (i64→ptr<1>) is the load-bearing half — EITHER end being opaque kills the
   fold — so consumer-side (ptrtoint) barriers are droppable defense-in-depth.
2. ~~Any lowering that pattern-matches the CAST forms downstream~~ **FOUND
   AND RESOLVED (§7.5):** exactly one exists —
   `rewriteUsesViaShadowSlot` (EcoToLLVMFunc.cpp:219-227) keys on raw
   `PtrToIntOp` + single-store to skip the shadow-root prologue store. The
   shadow-root frame is classified LEAVE (memory-mediated, fold-immune, §8),
   so the matched pair stays raw and the heuristic is untouched. If a future
   change ever barriers the prologue, this match breaks — co-update both.
   ExpandInlineDeref (markers), EcoBoxedStoreVerify (StoreOp attr, not
   casts), and EcoPtrIntVerify (checks restored casts post-strip under the
   §2.2 placement) are all confirmed compatible.
3. The strip's cast insertion point must preserve dominance for multi-use
   barrier results (build the cast at the call's position — the call
   dominated all its uses including post-RS4GC statepoint gc-live operand
   lists rewired by RAUW, so dominance holds by construction; the fatal
   check catches mistakes).
4. Residual un-inlined population after the lift is the mismatched-ABI class
   (sites whose stamped view ≠ callee signature stay indirect by design —
   see §E1.6: do NOT revive the coercing fold). If Run O shows that class is
   hot, the fix is callee-side (AbiCloning-family), a separate plan.
5. **Deferred `rs4gc-after-opt` mode (upside, out of scope):** barriers are
   also the missing enabler for that experimental mode — whole-module -O2
   pre-RS4GC is unsound today for exactly this fold class. But enabling it
   needs its own motion-hazard audit (full -O2 contains passes that move
   code; §2.2.1's conservative attrs are necessary but not shown
   sufficient there). Do not couple it to this plan.

---

## 7. Validation check against code (2026-07-21)

A line-level reasoning pass over every file this plan touches. Each premise
below was VERIFIED against the code (anchors current as of this date);
corrections have been folded into §1-§6 and are cross-referenced here.

### 7.1 The fold environment — "nothing simplifies pre-RS4GC" verified at
### the pass level

Every transform that runs between EcoToLLVM emission and the RS4GC rewrite
was enumerated; none can fold an opaque call, and none folds cast pairs:

- `expandInlineDerefs` (EcoBackend.cpp:698): pattern-expands
  `__eco_resolve_fwd` markers only.
- `runCapInlinePrepass` (EcoBackend.cpp:826): AlwaysInlinerPass —
  `InlineFunction`'s per-cloned-instruction `SimplifyInstruction` is THE
  hazard this plan neutralizes; it cannot fold calls to unknown external
  functions.
- `runCheapModuleIPO` (EcoBackend.cpp:128, parallel-opt mode only, runs on
  barrier IR before the split): IPSCCP + GlobalOpt + GlobalDCE — no
  inliner, no InstCombine/InstSimplify. IPSCCP treats calls to external
  declares as overdefined; GlobalDCE cannot drop used declarations.
- `addEcoGCPipeline`'s prologue (EcoPtrIntVerify.cpp:447): mem2reg + SROA +
  `FoldExtractValuePass` — InstCombine/InstSimplify DELIBERATELY excluded
  (documented fptosi rationale); FoldExtractValue touches only
  insertvalue/extractvalue chains. mem2reg/SROA cannot promote the
  GC-registered slot allocas (they escape into `eco_gc_push_stack_range`),
  so memory-mediated crossings stay in memory.
- MLIR side: NO canonicalizer runs after EcoToLLVM (removed, measured
  byte-identical — EcoPipeline.cpp:76-84) and no MLIR inliner pass exists in
  the pipeline (only the dialect interface registration). So
  `llvm.ptrtoint(llvm.inttoptr(x))` cannot fold at the MLIR level either.
- `internalizeAndDCEForExecutable` runs driver-side (eco-boot.cpp:794,
  EcoNativeDriver.cpp:240) before the backend: declarations are not
  internalized, used declarations survive GlobalDCE.

### 7.2 The helper funnel — plan premise PARTIALLY STALE, corrected in §2

Live call-site inventory (33 total, all in `Passes/`):

| wrapper | sites | locations |
|---|---|---|
| `heapLoadI64ToValue` | 3 | Heap:91 (`emitInlineBoxedLoad` — every boxed field projection incl. the culprit tuple case), Heap:1063 (array.get), ValueAgg:544 |
| `heapStoreValueToI64` | 5 | Heap:512 (`widenFieldToI64`), Heap:1138 (array.set — feeds the `eco.boxed_slot`-tagged store), ValueAgg:64 (local widen copy) |
| `globalLoadI64ToValue` / `globalStoreValueToI64` | 1 / 1 | Globals:70 / Globals:96 |
| `closureStoreValueToI64` | 6 | Closures:798, 810, 1071, 1677; ValueAgg:704 |
| `argsSlotStoreValueToI64` | 2 | Closures:1902, 2023 |
| `wrapperLoadArgSlotToValue` | 5 | Closures:490-524 (only its `isHPtrLLVMType` branch is a slot crossing; the plain-AS0 branch is kernel-pointer ABI, stays raw) |
| `wrapperReturnValueToPtr0` | 7 | Closures:582-617 (AS0 wrapper exit — NOT converted) |
| `caseScrutineeToI64` | 1 | ControlFlow:596 (tag class — NOT converted) |
| raw `valueToI64` | 2 | ErrorDebug:68, 118 (immediate gc-leaf call args — NOT converted) |
| `closureLoadI64ToValue`, `argsSlotLoadI64ToValue` | 0 | DEAD — v2's typed loads replaced the closure-load path; the live args-slot-load idiom is the raw straggler at Closures:1137 (§8) |

Consequence: "route the helpers" alone does NOT cover the load side of
args-slot crossings — the §8 stragglers are mandatory, not hygiene.

### 7.3 RS4GC equivalence — the zero-delta gate is realistic

`RewriteStatepointsForGC`'s base-pointer analysis treats BOTH
`IntToPtrInst` and `CallBase` results as base defining values, and gc-leaf
calls (attr present on the declaration via the existing
`getOrCreateFunc(gcLeaf=true)` passthrough mechanism, translated to an LLVM
fn attr — the same mechanism every existing gc-leaf runtime decl uses and
RS4GC already honors) receive no statepoint. Liveness extents are identical
(1:1 instruction swap at identical positions: the barrier call USES its
ptr<1> operand exactly where the ptrtoint did; produces its ptr<1> result
exactly where the inttoptr did). Statepoint placement, live-set membership,
and live-set ordering (deterministic IR-order visitation) are therefore
unchanged, and the strip restores the casts at the same positions →
post-strip IR should be exactly today's. The V3.1 binary-diff gate stands,
with the textual post-RS4GC-dump diff as the localization fallback.

### 7.4 Verifier compatibility

- `EcoPtrIntVerify` inspects only `PtrToIntInst`/`IntToPtrInst`; barrier
  calls are invisible to it, and under the §2.2 placement it runs AFTER the
  strip, i.e. on restored casts = today's verified shape. Its accept-lists
  already cover every restored form (store/gc-leaf-call uses; load/call/phi
  operands — `verifyIntToPtr` accepts `CallInst` operands explicitly).
- `EcoBoxedStoreVerify` keys on the `eco.boxed_slot` StoreOp attribute
  (attached in the array.set lowering), not on cast forms; the validator
  consumes i64 bits regardless of whether they came from a ptrtoint or a
  barrier call. Compatible unchanged.

### 7.5 Shadow-root machinery — leave BOTH sides raw (and why that's sound)

`installShadowRootPrologue` (Func:158, ptrtoint→store into the registered
frame) and `loadValueFromShadowSlot` (Func:189, load→inttoptr) form
memory-mediated round-trips through an ESCAPED alloca:
`SimplifyInstruction` cannot see through memory (no store-to-load
forwarding during inlining), mem2reg/SROA cannot promote the escaped frame,
and even a hypothetical fold-to-adjacent-store is harmless (identical bits
land in the GC-visible slot; the hazard requires a folded i64 to LIVE
ACROSS a statepoint in SSA, which immediate-store/immediate-convert shapes
never do). Additionally `rewriteUsesViaShadowSlot` (Func:219-227)
pattern-matches the raw prologue `PtrToIntOp` — the §6.2 risk instantiated —
so leaving the pair raw is both sound and required.

### 7.6 Sharpened hazard model (informs REP_LLVM_002 wording and §6.1's
### mitigation lever)

The ONLY dangerous simplification is `ptrtoint(inttoptr(x)) → x`
(`inttoptr(ptrtoint(p)) → p` restores the tracked value and is safe;
cross-addrspace forms don't fold), and it is dangerous ONLY when the erased
hop's live range crosses a statepoint. EITHER end being opaque blocks the
fold. Hence: producer-side barriers (i64→ptr<1>, the slot DECODE direction)
are the load-bearing half — with every relocatable-pointer producer
barriered or typed, no surviving raw `ptrtoint` has a foldable partner
(embedded-constant `inttoptr` partners fold harmlessly: constants are
GC-invariant). Consumer-side barriers are defense-in-depth for future
passes that can fold through memory (InstCombine under a hypothetical
rs4gc-after-opt world). Both sides ship per §2; the asymmetry is the
documented fallback if §6.1's wall budget trips. Corollary: OVER-barriering
is always sound (an unnecessary barrier is just an opaque hop that strips
to a cast) — when provenance is ambiguous in §8, barrier it.

### 7.7 Residual items verified

- Partition split preserves per-partition barrier decls + their gc-leaf
  attr (same property every runtime decl relies on); each worker strips its
  own module copy — no sharing.
- The JIT (`JITInvokePacked`) and `DumpLLVMText` paths both take the serial
  RS4GC branch (EcoBackend.cpp:944-947: `deferRS4GC` and `rs4gcInWorkers`
  are both EmitObjectFile-only) → strip inherited.
- `gc "eco-gc"` attr compatibility under AlwaysInliner: empirically settled
  by shipped v1 (257 bodies inline today).
- Barrier symbols never reach a linker (stripped pre-codegen on every path;
  fatal check otherwise), so no runtime/kernel symbol work is needed.
- E2E/corpus discipline: the harness binary cache is env-blind (memory:
  LSS 3.6 lesson) — the V3.1/V3.2 "both env states" gates need touch-all /
  clean rebuilds between legs, same as every env-sensitive gate before.

## 8. V3.0 crossing-audit table (DRAFT from the §7 validation pass —
## re-verify anchors at implementation time)

26 raw cast emissions in `Passes/` (ZERO elsewhere in `runtime/src` —
grep-verified) + the §7.2 helper funnel. Classification:

**CONVERT (route through helpers → barriers):**

| site | idiom | note |
|---|---|---|
| Closures:1137 | `load i64` from `outClosures[]` (GC-registered group-closure result buffer) + `inttoptr` | THE live args-slot-LOAD straggler; route via `argsSlotLoadI64ToValue` (currently dead — this revives it) |
| Closures:2199 | ptr→i64 into generic-apply args buffer store | AS1 arm ONLY → `argsSlotStoreValueToI64`; AS0 arm must stay a raw ptrtoint (helper passes AS0 through → i64 store type error) |
| Heap:1369 (`castToHPtr` i64 branch) | i64→ptr<1> in alloc-group lowering (used at :1464, :1563, :1603) | AUDIT provenance of the i64 form; per §7.6 barrier if ambiguous |
| Heap:1344/1352 (`castToI64`), Heap:1390/1396 (`widenToI64ForInit`) | ptr<1>→i64 feeding group-init stores / gc-leaf init calls | store-side, immediate-consume; convert for uniformity (droppable per §7.6 if the wall budget trips) |
| All §7.2 slot wrappers | heap/global/closure/argsSlot load+store, `wrapperLoadArgSlotToValue` AS1 branch | the V3.1 routing set |

**LEAVE (with reason):**

| site | class |
|---|---|
| Heap:194/197/235, ControlFlow:386/427, Types:39/86, Closures:1580 | embedded-constant encode / null-init — GC-invariant words, folds harmless |
| Closures:620/623 + `wrapperReturnValueToPtr0` ×7 | AS0 wrapper-ABI exit (REP_LLVM_001's sanctioned AS0 bridge); InstSimplify does not fold cross-addrspace |
| Closures:149 | unboxed-slot load with pointer result type = AS0 kernel ptr; AS1-boxed took v2's typed-load branch above it — AS1 unreachable here |
| ControlFlow:596 (`caseScrutineeToI64`) | tag bit-test class, same-BB consumption; no foldable partner post-V3.2 |
| ErrorDebug:68/118 (raw `valueToI64`) | immediate gc-leaf call args (REP_LLVM_001(d)) |
| Func:158/189 + the Func:219-227 matcher | shadow-root frame — memory-mediated, fold-immune, and pattern-matched (§7.5); leave BOTH sides |
| BFToLLVM:1058 | Brainfuck dialect, AS0, no eco values |

## 9. AS BUILT (2026-07-21) — implementation record + gate results

### 9.1 What shipped (all in one pass; V3.1+V3.2 emission verified inert
### before the V3.3 lift was applied)

- **`Passes/EcoSlotCastBarriers.h` (new):** barrier symbol names + the
  `slotCastBarriersEnabled()` master switch (default ON;
  `ECO_SLOT_CAST_BARRIERS=0` disables). Shared by the MLIR emission helpers,
  the strip pass, and the backend prepass (the §V3.3 coupling).
- **`EcoToLLVMInternal.h`:** `slotValueToI64`/`slotI64ToValue` barrier
  primitives (strict pass-through parity with `valueToI64`/`i64ToValue`);
  all EIGHT role wrappers routed (heap/global/closure/argsSlot × load+store
  — including the two previously-dead load wrappers) +
  `wrapperLoadArgSlotToValue`'s ptr<1> branch; `EcoRuntime::
  getOrCreateSlotToHPtr/HPtrToSlot` decls.
- **`EcoToLLVMRuntime.cpp`:** the two decl builders (gc-leaf ONLY — the
  no-motion-attrs constraint documented at the decl site) + registration in
  `materializeAllRuntimeDecls` (the H4.2 freeze gotcha honored).
- **`EcoPtrIntVerify.cpp`:** `StripEcoCastBarriersPass` (~50 lines,
  `report_fatal_error` on any surviving reference — active in release),
  added in `addEcoGCPipeline` between `RewriteStatepointsForGC()` and
  `EcoPtrIntVerifyPass` — ONE placement covering all five RS4GC call sites
  + JIT + DumpLLVMText, with the verifier checking the RESTORED casts.
- **Stragglers (§8 CONVERT rows, all landed):** Closures outClosures[] load
  (revives `argsSlotLoadI64ToValue`); Closures generic-apply args store
  (AS1 arm only, AS0 stays raw); Heap alloc-group family (`castToI64`,
  `castToHPtr` i64 branch, `widenToI64ForInit` both hptr paths).
- **`EcoBackend.cpp` (V3.3):** guard conditional —
  `gcfreeOnly = ECO_CAP_INLINE_GCFREE_ONLY || !slotCastBarriersEnabled()`;
  `ECO_CAP_INLINE_NO_GCFREE_GUARD` DELETED; comment block rewritten to
  as-built.
- **Pins:** `test/codegen/slot_cast_barriers_emit.mlir` (pre-RS4GC barrier
  call + gc-leaf decl attr; intentionally fails under
  `ECO_SLOT_CAST_BARRIERS=0` — pins the shipping config; verified failing
  under =0 as a negative control) and `slot_cast_barriers_strip.mlir`
  (post-RS4GC dump: zero barrier refs + restored inttoptr). NOTE the
  harness supports only unprefixed `// CHECK:` lines and picks ONE emit
  mode per fixture (jit wins) — hence two single-mode fixtures, not one
  multi-RUN fixture.
- **`design_docs/invariants.csv`:** REP_LLVM_002 row added.

### 9.2 Gate results (chronological)

1. **IR-level smoke (construct_nested):** on-leg 4 barrier calls + 7
   leave-class casts = off-leg 11 casts (exact 1:1 swap); post-RS4GC dumps
   byte-identical across env states; JIT behavior identical.
2. **Codegen suite:** 387/387 barriers-on; barriers-off green except the
   intentional emission pin (negative control verified).
3. **Bootstrap chain (default env, barriers on):** full 8-stage bootstrap
   green; NOTE the cmake chain's Stage 5 pins node to
   `--max-old-space-size=4096`, so SOLVER-flavored binaries cannot be built
   via `ECO_MONO_ENGINE=solver cmake --build …` (OOM ~4 GB) — mint the
   all-keyed `.mlir` with the NATIVE binary (recipe below), which is what
   the prior sessions' `allkey-*` artifacts did too.
4. **All-keyed mint:** native subst-built barriers-on binary compiled the
   full solver+LSS+keyed Stage-7a: rc=0, 6:45, `allkey-v3.mlir` =
   12,573,140 B.
5. **ZERO-DELTA (V3.1/V3.2):** `eco-boot-native allkey-v3.mlir` barriers-off
   75.2 s vs barriers-on 77.3 s (+2.7 %, budget ≤ +10 %); output binaries
   (59,945,224 B) BYTE-IDENTICAL.
6. **Inert-correctness (V3.2):** the barriers-on binary ran the full
   Stage-7a workload rc=0 (6:29) and reproduced `allkey-v3.mlir`
   byte-identically (self-compile fixed point holds).
7. **Marking-set parity + lift population:** `ECO_CAP_INLINE_GCFREE_ONLY=1`
   marks EXACTLY 257 (v1 parity); lifted default marks 15,744 (+15,487
   GC-bearing); lifted lowering wall 76.6 s (no regression).
8. **Pre-gate (culprit class):** 100 newly-admitted bodies from the
   TypeCheck.IO-wrapper + Terminal_Main-lambda neighborhoods
   (`ECO_CAP_INLINE_LIST`) → workload rc=0, output byte-identical.
9. **THE gate (V3.3):** full lifted binary (15,744 inlined) → Stage-7a
   rc=0, 6:22, output BYTE-IDENTICAL to baseline.
10. **Corpus:** `--target check` 1628/1628 at the final config.
11. **Run-O-lite:** surviving direct `$cap` calls 11,294 → 5,161 (−54 %;
    ≈ the predicted mismatched-ABI + oversized residue); binary size
    59,945,224 → 59,606,392 (−0.56 % — inlining + DCE net shrink). Wall
    delta on single runs: 6:29 → 6:22 (within noise; the honest
    interleaved ×3 A/B is V3.4 / Run O, still open).

### 9.3 Repro recipe (the all-keyed legs, from /work)

```bash
BK=build/compiler/build-kernel
cmake --build build --target eco-compiler          # default chain (subst node stage fits 4 GB)
rm -rf $BK/eco-stuff && (cd $BK && ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 \
  ./bin/eco-compiler make --optimize --kernel-package eco/compiler \
  --local-package eco/kernel=/work/eco-kernel-cpp \
  --output=bin/allkey-v3.mlir /work/compiler/src/Terminal/Main.elm)
cd build/compiler
/work/build/runtime/src/codegen/eco-boot-native $BK/bin/allkey-v3.mlir -o $BK/bin/allkey-v3-lift
# workload leg: rm -rf eco-stuff, run allkey-v3-lift with the same make args
# → rc=0 + output cmp-identical to allkey-v3.mlir is the standing gate.
```

### 9.4 V3.4 — Run O DONE (2026-07-21; full record in
### `benchmarks/runtime-calls.md` §Run O)

- **Interleaved wall A/B ×3** (all-keyed census binaries, cold subst
  workload, stock GC, majors recorded — all legs 10): guard/v1
  4:26.40/4:30.69/4:27.22 (mean 4:28.1) vs lift 4:28.86/4:28.26/4:31.41
  (mean 4:29.5) → **wall-NEUTRAL** (+0.5 %, inside the noise band); the
  i-cache concern does not materialize.
- **Census sanity PASSED:** all six timed legs identical to the last digit
  (`sat=653,394,605 fast=99,563,928` — the Run-M generation); every
  workload output byte-identical (12,110,547 B).
- **`ECO_CAP_INLINE_MAX_INSTS` sweep** (now meaningful — size finally
  binds): T=64→15,744 marked / 59,639,688 B / 5,183 survivors;
  T=128→18,033 / 59,368,968 / 2,926; T=256→19,247 / 59,183,608 / 1,711.
  Monotone, binary keeps shrinking, walls flat, outputs identical — no
  cliff. **Default stays T=64.** The T=256 residue ≈ the true
  mismatched-ABI floor (~1,711 calls); ~3,470 of T=64's survivors are just
  the oversized class.
- Prepass cost at the lift: 165 → 332 ms inside a ~208 s lowering; total
  lowering wall unchanged.
- **Verdict:** E1.3 closes as a correctness/infrastructure win, not a wall
  win on this (allocation/GC-bound) workload — the full population inlines
  for free. Remaining structural residue = the mismatched-ABI class
  (≈1.7 K calls): callee-side AbiCloning-family work (§6.4), a separate
  plan, only if a census ever shows it hot.

### 9.5 Battery items 4-5 results (validation builds, 2026-07-21)

- **EcoPtrIntVerify leg (battery 4):** separate tree `/work/build-val`
  configured with `-DECO_LOWERING_VALIDATION=ON -DECO_HEAP_VALIDATE=ON`
  (same compiler/flags as the `build` preset). Its `eco-boot-native`
  lowered `allkey-v3.mlir` under the FULL lift (15,744 bodies inlined):
  rc=0, verifier SILENT over the post-strip inlined IR (2m02s wall with
  the audit passes on). The §2.2 placement means the verifier checked the
  RESTORED casts of the inlined bodies — the gap-closure note is appended
  to `plans/ptrint-boundary-verifier.md`.
- **ECO_HEAP_VALIDATE bounded leg (battery 5):** the validation-runtime
  binary from that lowering compiled `Compiler/Type/Solve.elm` (55-module
  closure, warm deps) under a tiny nursery
  (`ECO_HEAP_CONFIG={"nursery_block_count":4}`): 108.4 M objects, 149
  minor + 1 major GC cycles forced through the inlined code paths with
  per-slot stale-pointer validation — clean exit. (Gotcha for future legs:
  `ECO_HEAP_CONFIG` takes a FILE PATH, not inline JSON.)
