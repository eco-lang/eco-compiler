# MLIR split backend 01: capacity-hoisting plan on the MLIR side

**Master plan:** `plans/mlir-split-backend.md`. **Status:** IMPLEMENTED 2026-10-02 (I1–I8; S6
split-time attribute copying deferred to the master plan's split milestone; results in
"Implementation results" at the end of Part II). Specified 2026-10-02. Part I (§0–§11 plus its adversarial review) is the feasibility analysis; Part II
is the build specification. Plan 00 (SP2) measured an **exact** MLIR/LLVM match on the
self-compile (75,775 functions, once K = 512).

**Research:** `design_docs/mlir-level-partitioning-whole-program-steps.md` §3.
**Background:** `plans/capacity-check-hoisting.md` (CGEN_074), `plans/gc-free-function-propagation.md`
(CGEN_072), sibling plans 03 (reachability) and 02 (gc-leaf propagation).
**Invariants touched:** CGEN_074, HEAP_034, CGEN_072, CGEN_077 (read-only), REP_LLVM_001/002
(no new casts; nothing here emits any).

## 0. Verdict

**Feasible, but the outline's "identical results with three emulations" was too optimistic.**
On the facts themselves the outline holds: Phase A's inputs can be reproduced exactly on
llvm-dialect MLIR. The audit below needs **seven** emulations, though, not three. It also found
two problems the outline missed:

1. **Ordering hazard with 02 (§3).** Today's Phase A tests `callsGCLeafFunction` *before* it
   tests "defined callee". That order is safe only because no generated function is stamped
   gc-leaf until after hoisting. Once 02 stamps in MLIR, a covered callee is *also* gc-leaf,
   and any LLVM-side re-run of Phase A would treat a call to it as transparent. That under-counts
   the caller's budget, which means bumps past the clamped end, which means heap corruption.
   The same stamps would also silently lengthen Phase D runs, so the output would change.
2. **The per-partition result can be verified locally (§4.3), given one global premise.** A
   one-step check per partition proves the budget guarantee: own bytes plus callee-attribute
   contributions must be ≤ the function's budget attribute. That turns "trust the MLIR plan"
   into "verify it", and it catches a wrong marker table on post-expansion IR. **The check is
   sound only if every cross-partition declaration carries exactly its owner's `eco-cap-*`
   attributes** (adversarial review A1/A2): a stale-smaller budget, or a dropped `covered` bit,
   passes every local check and still corrupts the heap. The split-time equality check (S6)
   is therefore a load-bearing hard error, not a cross-check.

3. **The adversarial review (end of file) found three more unsound holes in this outline:**
   - a decl copy that loses `covered` is *not* fail-safe;
   - a plan stamp riding on the marker decl misses marker-free partitions;
   - an executable plan applied to a non-exe output.

   It also found two wrong rules in §4.3: in-loop callees, and budget-0 functions with ⊤.
   All are fixed in place.

Expected payoff is small in isolation: `capacity-hoist analysis (serial)` is 0.94 s
(`benchmarks/backend-opt-loop.md:226`) for all of A–D2 together. The step is a **prerequisite
of the split**, because Phase B/C cannot run per partition. It is not a speed-up on its own.

## 1. Today: order of events (`runEcoBackend`, `EcoBackend.cpp:3651+`)

| # | Step | Line | Relevance to hoisting |
|---|---|---|---|
| 1 | `expandGetTagMarkers` | 3655 | leaf marker → diamonds + `__eco_resolve_fwd` (leaf) |
| 2 | `expandListProjMarkers` | 3658 (def 2056, 2511) | head → `eco_list_head_hybrid` (leaf); **tail → `eco_list_tail_hybrid` (NOT leaf)** |
| 3 | `expandListCursorMarkers` | 3660 (2151, 2303) | diamonds; only leaf barriers + `__eco_resolve_fwd` |
| 4 | `expandStringLenMarkers` | 3663 (2449) | diamond + `__eco_resolve_fwd` |
| 5 | `expandValueEqFastPath` | 3667 (2373) | **marker → `Elm_Kernel_Utils_equal`, leaf only under `ECO_VALUE_EQ_GCLEAF=1` or a kernel `eco.gc_leaf` row**; the stamp is module-wide (2392) |
| 6 | scratch-helper gc-leaf stamps | 3671 | **backend-only** stamps on `eco_scratch_mark/push_boxed/push_scalar` |
| 7 | `expandInlineDerefs` | 3677 (1330) | diamond + `eco_follow_forward` (leaf) |
| 8 | **`applyCapacityHoisting`** | 3700 (2949) | Phases A (2958–3040), B (3042), C (3199), D (3230), D2 (3307) |
| 9 | `expandInlineAllocs` | 3714 (1506) | consumes `CapHoistDecisions` (1388) keyed on `Function*` / `CallInst*` |
| 10 | `expandRootRangeOps` | 3724 (1726) | leaf calls → TLS stores; after hoisting |
| 11 | `expandSatMarkers` | 3730 (1853) | **adds an indirect fast call** in a new block; after hoisting |
| 12 | `runCapInlinePrepass` | 3737 (3567) | `$cap` with ≤ 64 instructions → AlwaysInline; after expansion |
| 13 | `propagateGcFreeLeafAttrs` | 3747 (2740) | the first point at which generated functions become gc-leaf |

Before step 1, the exe drivers run `internalizeAndDCEForExecutable` (`EcoNativeDriver.cpp:240`,
`eco-boot.cpp:822`). That step is what makes `hasLocalLinkage` true. `ecoc` (`.o`, `-emit=llvm`,
JIT), `EcoRunner`, **and the `.o`/`.so`/`.node` outputs of `EcoNativeDriver` and `eco-boot`**
(`EcoNativeDriver.cpp:236`, `eco-boot.cpp:813`) skip it, so on those paths M1 collapses to almost
nothing (the CGEN_074 record: `coverable=7`, `excl_linkage=15810`) and only M2 remains. Note that
both exe drivers decide "executable or not" only *after* the MLIR pipeline has run
(`runPipeline(module, stats)`, `EcoNativeDriver.cpp:88`, knows no output kind) — see §6.

## 2. Information-flow audit: every fact A–D consume

Columns: where the fact is produced; the MLIR view (end of `buildEcoToLLVMPipeline`, after
`EcoTailConversions` and 03); the LLVM view (at step 8). "Same" means equal by construction,
given the emulation named in the last column.

| Fact | Produced | MLIR view | LLVM view at step 8 | Same? / emulation |
|---|---|---|---|---|
| marker size | `emitInlineAllocWithHeader` (`EcoToLLVMInternal.h:966`), 13 sites (Heap 6, ValueAgg 6, Closures 1) | `llvm.call @__eco_alloc_inline(%c)`, where `%c` is an `llvm.mlir.constant`, possibly CSE'd or hoisted to another block | `ConstantInt` operand | Same: match through `getDefiningOp` (E1) |
| marker in CFG cycle | lowering CFG (scf→cf in `EcoTailConversions`) | MLIR blocks | blocks after steps 1–7 split them | Same (§2.1); unreachable blocks need E2 |
| call set / leafness | lowering + steps 1–7 | marker calls (declared gc-leaf in `EcoToLLVMRuntime.cpp:622–997`, **except the six cursor markers, created without passthrough by `EcoListCursor.cpp:110`**) | expanded calls | **Differs** for list-tail, value-eq and the cursor markers: marker table (E3) |
| backend-only stamps | step 6, step 5 | absent | present | **Differs:** move them to MLIR, or mirror them (E4) |
| callee identity | `llvm.call @f` / `addressof` + indirect | callee symbol, or `addressof` operand | `getCalledFunction()`, which is FTy-strict (`InstrTypes.h:1348`) | Same: E5 |
| `callsGCLeafFunction` | decl passthrough, intrinsics, TLI | passthrough strings; `llvm.intr.*` are ops, not calls | call-site attr → called-operand attr (ignores FTy) → intrinsic → TLI libfunc | Same: E6 |
| eligibility | 03 internalize/DCE; `addressof` | linkage attr; `addressof` uses | `hasLocalLinkage`, `hasAddressTaken()` (casted direct call = taken), `isInterposable` | Same: E7, but only if 03's DCE equals GlobalDCE |
| headroom breaker | name list (2889) | callee symbol name | callee name | Same |
| K, M2, mode | env (140–182) | env read in-process | env | Same in-process; stamp into the plan (§5) |

### 2.1 CFG cycles are preserved by steps 1–7

- Every pre-hoisting expansion uses `SplitBlockAndInsertIfThen(Else)` or an explicit
  head/test/slow/cont diamond (`2373`). None of them adds a back edge.
- Splitting a block keeps every original instruction in the same SCC: the new blocks lie on
  every path through the old block. So `inCycle(marker)` is invariant.
- No expansion emits an `__eco_alloc_inline` marker. That marker is created only in MLIR, so
  the marker population is identical on both sides.
- **E2, unreachable blocks.** `computeBlockCycles` (2899) walks `scc_begin(&f)`, which starts
  at the entry block. A marker in an unreachable block is therefore *not* in a cycle and its
  bytes count toward `ownBytes`; any call in such a block still drives ⊤.
  - The MLIR side must reproduce exactly this: SCCs over the reachable subgraph, and calls in
    every block.
  - **Verify** that translation keeps unreachable blocks. `getBlocksSortedByDominance`
    (`TopologicalSortUtils.h:109`) appears to include them, but this needs confirming.
  - Translation reorders blocks, which matters only for the census `TopReason` labels (the
    first-seen reason wins, 3009–3040). Budgets and coverage are order-free.

### 2.2 Which expansions change the call set (E3, the marker table)

| Marker (MLIR decl, gc-leaf) | Expands to (step) | Effect on Phase A |
|---|---|---|
| `__eco_get_tag_inline`, `__eco_list_head_inline`, `__eco_string_len_inline`, `__eco_resolve_fwd` | leaf calls + diamonds | Transparent on both sides |
| `__eco_list_cur*_inline`, `__eco_list_step_*_inline` | leaf calls + diamonds (step 3) | **Not** gc-leaf in MLIR (`EcoListCursor.cpp:110` `ensureFn`, no passthrough). The table must override the decl to *transparent*; a raw-decl reading makes every cursor loop's function ⊤ (conservative, but a validate diff on every cursor function). Same finding as 02 O2 |
| `__eco_list_tail_inline` (`EcoToLLVMRuntime.cpp:693`) | `eco_list_tail_hybrid`, declared non-leaf (`:708`, `EcoBackend.cpp:2514`) | **MLIR must treat it as ⊤/Other.** Otherwise a function walking a chunked list's tail gets covered: an unsound allocation |
| `__eco_value_eq` (`:952`) | `Elm_Kernel_Utils_equal` arm 3 | The MLIR runtime decl of `Elm_Kernel_Utils_equal` is **always** gc-leaf (`EcoToLLVMRuntime.cpp:940`, kernel-opt-03 Phase 4) — but it is erased by the unused-decl strip (`EcoToLLVM.cpp:601–663`) when nothing uses it directly. Then `getOrInsertFunction` (`EcoBackend.cpp:2385`) mints a **non-leaf** decl unless `ECO_VALUE_EQ_GCLEAF=1`. So arm 3 is leaf iff a direct use survives in the *same module* or the env is set: a module-content fact that **changes per partition**. The split must copy the decl into every partition holding the marker. Nothing emits `eco.value.eq` today (2366), but the table must be right anyway |
| `__eco_sat_begin/_end` (`:880/886`) | expanded **after** hoisting (step 11) | Both sides see a leaf marker today. Exact identity needs the "hoisting view" = leaf. Soundness relies on the bracket containing the generic apply (non-leaf), which already makes the function ⊤. See open question Q3 |
| `eco_gc_push_stack_range` & co. | step 10, after hoisting | Leaf on both sides |

Two expansion details the table must also encode:
- An expansion's `getOrInsertFunction` returns an **existing** decl even when the requested type
  differs. The call then has a mismatched FTy, `getCalledFunction()` is null, and Phase A sees
  ⊤. Each table row must therefore record the callee type the expansion requests. S2 asserts
  that it equals the MLIR decl's type.
- The value-eq row above depends on module contents, not on the marker alone.

**Consequence:** the may-GC table shared with 02 needs **two columns**:
- the *hoisting view*: what step 8 sees, with sat/root-range still unexpanded;
- the *final view*: what RS4GC sees, which is what 02 needs. There, sat is may-GC.

A single "may-GC" bit would make either 01 or 02 differ from today.

### 2.3 Backend-only and env-dependent stamps (E4)

- **Scratch stamps (3671).** The decls come from `EcoListTemplate.cpp:603` `ensureDecl` as
  `func.func` decls, and get no passthrough. Move the stamp into the MLIR decl creation, as 02
  step 2 also plans. Until then, MLIR Phase A would see three non-leaf callees, which is wrong
  but conservative: fewer covered functions and a validate diff.
- **`Elm_Kernel_Utils_equal` (2392).** It is stamped module-wide under `ECO_VALUE_EQ_GCLEAF=1`
  (default off). That stamp matters only for a decl minted by the expansion, because the MLIR
  runtime decl is already gc-leaf (`EcoToLLVMRuntime.cpp:940`). The MLIR pass must read the same
  switch *and* know whether the decl survived the strip (see §2.2).
- `eco_follow_forward` and `eco_list_head_hybrid` already carry gc-leaf in MLIR (`:629/:701`).
- `eco_bump_state` and `eco_ensure_nursery_slow` are created at or after step 8. They are not
  inputs.

### 2.4 Callee identity and address-taken (E5, E7)

- `emitFastClosureCall` (`EcoToLLVMClosures.cpp:1331–1350`) deliberately emits
  `llvm.mlir.addressof @X$cap` followed by an *indirect* `llvm.call`.
  - After translation, the called operand **is** the `Function`.
  - `getCalledFunction()` returns it **iff** the call FTy equals `X$cap`'s type. A match makes
    it a direct edge and not address-taken. A mismatch makes it an indirect call (⊤) **and**
    address-taken (`Function.h:995`: casted direct calls count unless
    `IgnoreCastedDirectCall`).
- The comment at `:1334` describes an "E1.2/E1.3 fold in `runCapInlinePrepass`" that rebuilds
  these as direct calls. **That fold no longer exists** (3567–3647). Treat the comment as stale;
  the MLIR rule must mirror today's raw `getCalledFunction`.
- **MLIR rule.**
  - An `addressof` result whose every use is the callee operand of an `llvm.call`, with callee
    type == `@X.function_type`, is a direct edge and not a take.
  - Any other use is a take: a global-initializer region, a store, a call argument, or a
    mismatched type.
  - A dead `addressof` creates no LLVM use, so it is **not** a take.
  - **`SymbolRefAttr`s in discardable attrs are not takes.** `_fast_evaluator` is copied onto
    `llvm.func` (`EcoToLLVMFunc.cpp:160–167`) and dropped by translation. 03's planned
    `eco.addr_taken` must use this LLVM meaning, not "any symbol use".
- **`callsGCLeafFunction` asymmetry (E6).** It accepts gc-leaf on the called operand *ignoring*
  FTy, while edges require an FTy match. Emulate both. TLI libfunc recognition uses
  `getCalledFunction`. Today the only libm decls (`asin/acos/atan/atan2`, `:1159–1176`) are
  already stamped, but this must be measured (M3).
  - TLI is built from `m.getTargetTriple()` (`EcoBackend.cpp:2953`). The AOT drivers set that
    triple to `sys::getDefaultTargetTriple()` in `createEcoTargetMachine` (`EcoBackend.cpp:1144`)
    *after* translation. The MLIR module carries no triple. So the TLI arm is triple-dependent,
    and the JIT may differ. If M3's "TLI-only leaf" count is non-zero, the emulation must use
    the same triple per driver.
- **`isInterposable` (E7).** It depends on linkage plus the module's SemanticInterposition
  flag. Nothing sets that flag (grep: no hits), so linkage alone decides.
- **DCE dependency.** `hasAddressTaken` is evaluated *after* GlobalDCE. A dead global
  initializer or a dead function holding `addressof @f` makes `f` address-taken in MLIR and not
  in LLVM. 03 says its reach is a "sound superset". Any excess there shows up here as lost
  coverage and validate diffs, never as unsoundness.

### 2.5 Allocation grouping (CGEN_077) never reaches marker sizes

- Inline-eligible groups are split into singletons in `EcoGCPrepare`; each singleton becomes
  one marker.
- Mixed groups lower to `eco_gc_alloc_region_fast` (leaf, headroom breaker) plus
  `eco_gc_alloc_region_slow` (non-leaf), emitted together (`EcoToLLVMHeap.cpp:2002/2033`).
  That makes the function ⊤ on both sides, by name.
- Group sizes appear only as call operands, never as marker sizes. No emulation is needed.

## 3. Ordering hazard: gc-leaf stamps on generated functions

Today's code is correct only because CGEN_072 stamping (step 13) comes after step 8. Once 02
moves stamping into MLIR **before** the split, every LLVM-side classifier sees stamped
generated callees:

| Site | Test order today | Effect with 02's stamps present |
|---|---|---|
| Phase A (3019–3036) | breaker → `callsGCLeafFunction` → defined edge | A call to a **covered** callee (covered ⇒ stamped) becomes "transparent". The caller's budget drops that callee's bytes, so it is **unsound**. This hits the validate twin and any per-partition re-derivation |
| Phase D (3285–3302) | covered → leaf → breaker | Covered is tested first, so that is fine. A **budget-0** callee was a breaker (unstamped) and now becomes transparent. Runs get longer: sound, but the **output changes** |
| D2 re-walk (3330–3345) / §2.6(b) (3462–3471) | covered → leaf | Same as Phase D: sound, accepts more |

Required rules:
- **R1.** Every classifier tests the eco-cap attributes *before* `callsGCLeafFunction` whenever
  the callee is a generated function. "Generated" means it carries any `eco-cap-*` attribute.
  `EcoCapHoistPlan` stamps **every** definition with `eco-cap-budget` or `eco-cap-top`, so a
  correct copy is never attribute-free. **Gap:** this definition cannot recognise a decl whose
  copy lost *all* `eco-cap-*` attributes but kept a copied gc-leaf. Such a decl reads as a plain
  leaf decl, and the callee becomes transparent. Two checks close it, aligned with 02's F11:
  - the split-time check (S6), which must assert presence, not just equality;
  - a **per-partition trusted-set assert**: any gc-leaf declaration with no `eco-cap-*` must
    be a known runtime, kernel (`Elm_Kernel_*` stub) or expansion-created name, taken from
    the shared marker/runtime table (Q2). Otherwise it is a hard error.

  The assert costs one pass over declarations.
- **R2.** `EcoCapHoistPlan` asserts that no defined `llvm.func` carries gc-leaf when it runs,
  which pins 01 before 02.
  - **Mirror on the LLVM side (02 O1):** compute-mode `applyCapacityHoisting` refuses to run on
    a module where any *definition* already carries gc-leaf. That covers the S3 validate twin
    and hand-written inputs, once 02's MLIR stamps exist.
  - A generated callee with gc-leaf that is neither covered nor budget 0 is also a hard error.
    This is the "⊤ ∧ GC-free is empty" premise below.
- **R3.** For byte-identity, plan-given Phase D treats a budget-0, non-covered generated callee
  as a breaker, exactly as today.
- **Later opt-in, R3′.** Treating budget-0 callees as transparent is sound and could be shipped
  today, independent of the split. A budget-0, non-⊤ function has no markers at all (an
  in-cycle marker is ⊤) and no breakers. Every one of its calls is either leaf or a call to
  another budget-0 function; it is *not* call-free. That may include a zero-byte recursive SCC
  (3127–3157). Measure the opportunity first (M6).
- **Check the premise.** "⊤ ∧ GC-free" is empty today: every ⊤ reason implies a non-leaf call,
  given that `eco_alloc_*_fast` is decl-only and region_fast always pairs with region_slow.
  **The one exception is `isInterposable` (2973),** which is ⊤ with no call at all. No generated
  function is interposable today, so assert that too. Assert the premise at the split, because
  R1 relies on gc-leaf never coexisting with a breaker.

## 4. Do the decisions reach every consumer after a split?

### 4.1 Consumers and what they need

| Consumer (per partition) | Needs | Source after the split |
|---|---|---|
| `expandInlineAllocs` covered test (1404) | `f ∈ coveredFns` for the marker's own function | `eco-cap-covered` on the definition, **including `$cap` available_externally copies** |
| `expandInlineAllocs` M2 test | `CallInst* ∈ uncheckedMarkers` | Local Phase D in the same `llvm::Module`. Pointers stay valid because the plan is never computed in another module |
| Phase D element (3286) | callee covered + budget | Attributes on the def **or the decl** |
| Phase D transparency (3299) | `callsGCLeafFunction` + R1/R3 | Decl passthrough + eco-cap attributes |
| §2.6(a) (3427) | every user of a covered `f` is in a run or a covered function | Users **inside this partition** only. Today's loop iterates only *defined* covered functions (3436), and in a caller's partition the covered callee is a **decl**. The plan-given check must iterate decls carrying `eco-cap-covered` too, or no partition ever checks a cross-partition call site. A non-call use (`addressof` in another partition) also fails here, which turns the global "never address-taken" fact into a local check. The union over partitions is then global |
| linkage sanity (new) | covered ⇒ uninstrumented callers impossible | Plan-given mode asserts at step 8: every covered definition has local linkage, or, in split mode, hidden visibility. That catches an MLIR plan computed under "executable" assumptions on a `.o`/`.so`/JIT output (§6). Eligibility is never recomputed, so nothing else would notice |
| §2.6(b) (3445) | callees of a covered `f` are covered or budget-0 | The `info.find(callee)` path (3462) only works for definitions. A cross-partition **decl** falls through to `callsGCLeafFunction` and either aborts (no stamp) or relies on 02's stamp. It must read the eco-cap attributes instead |
| §2.6(c), unchecked-count cross-check (1679) | local | unchanged |
| `CapHoistDecisions` object | one per module | one per partition worker, never shared |

**Can a function's own markers' unchecked status be decided per partition from attributes
alone? Yes.**
- **Covered `f`:** all of its markers are unchecked, from its own `eco-cap-covered`.
- **Non-covered `f`:** the M2 status of its markers comes from local Phase D. Phase D reads
  only:
  - its own marker sizes;
  - K and M2 from the plan stamp;
  - callee names (breakers);
  - callee eco-cap attributes and decl passthrough.
- No callee body is ever consulted. This must be enforced structurally: the plan-given code
  path must take no `Function&` body of any callee.

### 4.2 Attribute encoding

- On every **defined** generated function: passthrough `["eco-cap-budget","N"]` when not ⊤,
  or `"eco-cap-top"`; plus `"eco-cap-covered"` when covered.
- Covered implies eligible, budget > 0, and not ⊤. For a callee's contribution, `{top | N,
  covered}` is sufficient:
  - covered → N;
  - N = 0 → 0;
  - otherwise → ⊤.

  The `eligible` bit itself never needs to travel.
- Absence on a decl means "unknown" and is treated as ⊤. Phase D then breaks the run there,
  and §2.6(b) or §4.3 aborts if a *covered* function calls it (loud).
- **Correction (review A2): a missing copy is NOT fail-safe.** If the owner's `g` is covered,
  its markers expand *unchecked* in the owner's partition. A **non-covered** caller in another
  partition that sees `g` as ⊤ breaks the run and emits no ensure for `g`. That is an unchecked
  bump with no reservation, i.e. heap corruption. No local check fires:
  - the caller's partition does not know `g` is covered;
  - the owner's partition does not see the call.

  The same holds for a dropped `eco-cap-covered` bit that kept the budget.
- The dangerous directions are therefore:
  - a *missing* or *weakened* covered bit;
  - a *stale-smaller* budget.

  Both pass every per-partition check. The split must copy the attributes mechanically from
  the owner, then run a **mandatory hard-error** equality-and-presence check (S6). A plain
  "safe direction" argument cannot replace it.

### 4.3 Local Bellman verification (the safety net)

Per partition, after steps 1–7 and before plan-given D, re-run **LLVM Phase A locally** on
every definition. It costs a single linear scan of the partition (parallel). Callee facts come
from attributes, never from bodies. Then assert:
- **Covered f:** no ⊤ reason in the *post-expansion* body, i.e. no in-cycle marker, no
  non-leaf or indirect call, no breaker. **An in-loop call must have contribution 0, or the
  check fails.** It must *not* be counted as 0: that would accept a covered `f` calling a
  covered `g` inside a loop, mirroring Phase B's `e.second && c > 0 ⇒ ⊤` (3172). Then
  `own(f) + Σ contrib(callee attrs) ≤ budget(f)`. Use `==` in identity mode.
- **Budget-0 f:** no ⊤ reason (same list as above), no markers at all, and every contribution
  = 0. Without the no-⊤ clause, a budget-0 attribute on a GC-ing function would pass. §2.6(b)
  and Phase D would then admit it as GC-free.

**Why this is enough — and its premise.** Assume every covered function satisfies the
inequality, and every call to a covered `g` is either inside a covered function or a member of
a run whose ensure counted `budget_seen(g)`. The run case is guaranteed by D2's re-walk plus
§2.6(a) extended to decls (§4.1). Then, by induction on dynamic call depth, the bytes bumped
under an ensure never exceed the run's reservation, **provided `budget_seen(g) ≥ budget_def(g)`
and `covered_seen(g) = covered_def(g)` for every decl in every partition.** That proviso is the
one global fact no partition can check. S6's split-time equality check supplies it.
- A cycle with positive demand cannot satisfy the (non-strict) inequalities: summing them
  around the cycle gives Σ own ≤ 0. A cycle given a finite budget by mistake is caught too.
  A zero-demand cycle can pass, and that is harmless.
- It runs on the **post-expansion** IR, so a wrong marker-table entry (for example list-tail
  marked leaf) becomes a build error rather than heap corruption.
- It is per-partition and needs no global view **beyond the premise above.**

This replaces "trust the MLIR plan" with "verify every partition" and should ship in the first
plan-given step.

### 4.4 `$cap` bodies across partitions

- **Facts.**
  - `$cap` clones come from `Lambdas.elm:327/413` (`_fast_evaluator` at `:242`).
  - Calls to them are `addressof` + indirect (§2.4). Matched-FTy sites become direct after
    translation; AlwaysInliner inlines only those.
  - How many `$cap`s are address-taken is **unmeasured**. The C0 census's 3,250
    `excl_addrtaken` (`capacity-check-hoisting.md:702`) counts *all* finite-budget address-taken
    functions, not `$cap`s. A `$cap`'s only LLVM take is a mismatched-FTy fast call: the
    `_fast_evaluator` symbol ref is dropped. A `$cap` reached only through matched-FTy sites and
    direct calls from wrappers *can* be covered. Measure how many (M5).
- **No marker moves after coverage is decided.** The prepass (step 12) runs after
  `expandInlineAllocs` (step 9), so it splices *expanded* code.
  - A covered `$cap`'s unchecked bumps land where its call stood. That call was a run element
    or sat inside a covered caller, so the dominating ensure still dominates.
  - A non-covered `$cap` carries its own diamonds or ensures, and calls to it break runs.
  - So today's ordering is sound with no extra rule. The split must keep "expand, then inline"
    per partition.
- **Copies.** The available_externally copy in partition P must get:
  - the owner's eco-cap attributes, so P expands it identically;
  - declarations, with attributes, for all of its callees;
  - **transitively**, every `$cap` it calls directly. Without them, AlwaysInliner in P cannot
    reach the depth it reaches in the whole module.
  - **external visibility for everything the body references.** That includes the owner's
    *internal* functions and private globals (string literals, constant closures). Once the copy
    is inlined, P references them, so 03's referrer sets must count copy bodies, or P fails at
    link. This is the same obstacle as 03's finding 4; it is not specific to 01.
  - In plan-given mode the copy is a definition (`isDeclaration()` is false for
    available_externally), so §4.3, Phase D/D2 and §2.6 all run on it. That is correct, and it
    is why census sums must count owned functions only (S6).
- **Instruction counts.** Identical bodies give identical counts, so the ≤ 64 test agrees. This
  holds only if P's per-partition pipeline is attribute-driven everywhere; plan-given D is.
- **Exception: `ECO_CAP_INLINE_GCFREE_ONLY`.** `bodyIsGCCallFree` (2707) reads callee gc-leaf,
  which differs between P (decl, maybe stamped by 02) and the owner. That config is off by
  default, but it is a known identity break.
- **Order dependence.** AlwaysInliner's result on nested `$cap → $cap` chains can depend on
  module function order, and P's order differs from the whole module's. The result is
  deterministic but not identical to today. Measure the nested-chain count (M5).
- **Cleanup.** Erase the non-inlined available_externally copies right after the prepass.
  Otherwise RS4GC, 02's local check and -O2 spend time on bodies that codegen drops.

## 5. Design (revised)

1. **Shared core.** Split `applyCapacityHoisting` into:
   - a Phase A front end per IR, producing a neutral record `{ownBytes, top, reason,
     eligible, callees[(id, inLoop)], selfEdge}`;
   - an IR-neutral Phase B/C core (`EcoCapHoistCore.h`: Tarjan + contributions + coverage).

   One algorithm and two front ends, so the validate twin cannot drift in B/C.
2. **`EcoCapHoistPlan`** (MLIR, after `EcoTailConversions` and 03, before 02; last in
   `buildEcoToLLVMPipeline`, `EcoPipeline.cpp:183`).
   - Phase A runs in parallel per `llvm.func` with E1–E7; then the serial core.
   - It stamps the attributes in §4.2.
   - **Plan stamp:** `"eco-cap-plan"="v1;K=512;m2=1;mode=on;exe=1"`.
     - **It must NOT ride on the `__eco_alloc_inline` decl** (review A3). That decl exists only
       in a module or partition that holds markers.
     - A marker-free partition can still call covered functions in other partitions. With no
       stamp it would fall into compute mode, see those decls as ⊤, emit no ensure, and so
       corrupt the heap.
     - Carry the stamp as an LLVM module flag (`llvm.module_flags` in the LLVM dialect), or
       in-process on `EcoBackendJob`, which works for every driver because none of them
       serialize between the two steps.
     - Rule: any `eco-cap-*` attribute in a module without a plan stamp is a hard error.
   - The pass is gated exactly like today: `capHoistMode()` plus the `gcFreeLeafMode()` check
     at 3688–3698.
3. **Plan-given mode** in `applyCapacityHoisting`, entered iff the plan stamp is present.
   - A K/M2/mode mismatch with the current env is a hard error. This matters if a stale
     `-emit=mlir-llvm` file is re-lowered.
   - It runs the §4.3 verification, then D/D2 with R1/R3, then the §2.6 checks rewritten for
     declarations, plus the §4.1 linkage-sanity assert.
   - With no stamp **and no `eco-cap-*` attribute anywhere**, it uses today's compute mode, so
     hand-written LLVM inputs keep working. Compute mode also needs R1 once 02's stamps exist,
     because the S3 validate twin is a compute-mode run.
   - `EcoCapHoistPlan` must be idempotent on re-lowered `-emit=mlir-llvm` input that already
     carries attributes: either assert their absence or overwrite them.
4. **Strip** the `eco-cap-*` attributes after `expandInlineAllocs`, as the prepass already
   strips AlwaysInline. String function attributes never reach the ELF, but they renumber
   `attributes #N` groups in `-emit=llvm` dumps and are pass-local by design.
5. **Census.** `ECO_ALLOC_HOIST_DUMP` and the A–C part of the `[caphoist]` line move to the MLIR
   pass. Per-partition D counts are summed with atomics, and the line is printed once.

## 6. Paths and determinism

- **Drivers.** All four drivers (`ecoc.cpp:214`, `EcoRunner.cpp:190`, `EcoNativeDriver.cpp:107`,
  `eco-boot.cpp:385`) build the same pipeline, so the pass runs everywhere.
- **Linkage per path.**
  - Exe paths need 03's MLIR internalization (a pipeline option such as `executable=true`).
    **Plumbing obstacle:** `EcoNativeDriver::runPipeline(module, stats)` (`:88`) and
    `eco-boot` (`isExecutable` at `:813`, after the pipeline at `:385`) learn the output kind
    only after the MLIR pipeline has run, so the output kind must be threaded into
    `EcoPipelineOptions`. Getting this wrong is **unsound, not just slow**: a plan computed
    with `executable=true` for a `.o`/`.so` covers externally callable functions whose foreign
    callers emit no ensure. The `exe=` field of the plan stamp, plus the §4.1 linkage assert,
    turn that mistake into a build error.
  - The `.o`, `.so`, JIT and `-emit=llvm` paths must see unchanged MLIR linkage, which equals
    their LLVM linkage because they skip internalization.
  - The `main` → `eco_main` rename (`eco-boot.cpp:420`) happens after translation. 03 roots
    `main`.
- **JIT.** `allowTls` is unaffected; it applies to the expansion, not the plan.
- **-O0.** Hoisting still runs at -O0 (the prepass does not), so the plan is needed there too.
- **Determinism.**
  - Phase A is parallel but writes into per-function slots.
  - Tarjan iterates in symbol-table order. Budgets are order-free, and `TopReason` order
    affects only census labels.
  - Attributes are decimal strings.
  - Phase D order is per-function and local.
  - The only order-sensitive downstream effect is the `$cap` AlwaysInliner order (§4.4).

## 7. Measurements before implementation (all cheap, no output change)

| ID | Measure | Why |
|---|---|---|
| M1 | Split today's 0.94 s into A / B / C / D / D2 (stats scopes) | Sizes what leaves the serial path; D stays per partition |
| M2 | `[caphoist]` line at HEAD on the self-compile (C0 is from Aug, K=512) | Reference for every validate step |
| M3 | Counts: matched-FTy `addressof` calls, mismatched ones, calls that are leaf only by TLI or intrinsic, `__eco_list_tail_inline` / `__eco_value_eq` / `__eco_sat_begin` / cursor-marker sites, scratch-helper call sites, expansion calls whose FTy mismatches the existing decl | Sizes E3–E6; any non-zero "TLI-only" count needs explicit emulation |
| M4 | Markers and calls in unreachable blocks (LLVM), and whether translation keeps unreachable MLIR blocks | E2 |
| M5 | Covered `$cap`s; directly called `$cap`s per LPT partition; nested `$cap → $cap` direct-call depth | Copy cost and the AlwaysInliner order risk (§4.4) |
| M6 | Runs broken by calls to budget-0 generated callees (Phase D, extra counter) | Value of R3′; how much R3 holds back |
| M7 | MLIR-vs-LLVM defined-set and address-taken diff after 03 (needs 03's validate) | Upper bound on eligibility diffs |
| M8 | Cost of translating about 50k passthrough string attrs (translation + RSS) | Attributes on every function and decl |

## 8. Steps

| Step | Content | Acceptance |
|---|---|---|
| S0 | M1–M6; fix the stale comment at `EcoToLLVMClosures.cpp:1334` | Numbers recorded in this plan |
| S1 | Shared core refactor (§5.1). The LLVM front end stays the only user | Byte-identical ELF; identical `[caphoist]` line; `test/codegen` green |
| S2 | Marker table, two columns (shared with 02 step 1). Each expansion asserts it emits only table-allowed callees. Move the scratch stamps to MLIR decls; read the value-eq switch in MLIR lowering | Byte-identical ELF; `inline_alloc_tuple.mlir`, `gc_group_split_inline.mlir`, `kernel_gcleaf_stamp.mlir` green |
| S3 | `EcoCapHoistPlan` (census + attributes); **validate mode** `ECO_CAPHOIST_VALIDATE=1`: run LLVM A–C as today and diff `(covered, top, budget)` per function present in both; report reasons as a soft diff | Zero hard diffs on the self-compile, E2E and `test/codegen`. ELF byte-identical (LLVM still decides). Pass time recorded |
| S4 | Plan-given mode + §4.3 verification + R1/R3 + §2.6 for decls + linkage assert + attribute strip; plan stamp off the marker decl | Byte-identical ELF vs S3 on the self-compile; bootstrap fixed point. New fixtures: (a) covered callee as a **declaration** with attributes; (b) a covered callee pre-stamped gc-leaf, whose budget must not drop (R1); (c) a list-tail marker deliberately mis-tabled, which §4.3 must abort on; (d) a stale plan stamp K, which must abort; (e) a **marker-free** module that calls a covered decl, which must still get its ensure; (f) a covered `f` calling a covered `g` in a loop, with forged attributes, which §4.3 must abort on; (g) a covered definition with external linkage (an `exe=1` plan on a `.o`), which must abort; (h) a gc-leaf decl with no `eco-cap-*` and a non-runtime name (trusted-set assert, 02 F11), which must abort |
| S5 | `ECO_CAPHOIST_VALIDATE` also on `run-aot-e2e` and the GC-pressure stress set (`no-validator-self-compile` rule: validate-build unit + E2E + stress) | Green |
| S6 | Lands with master §4: attribute copying onto decls and `$cap` copies (transitive); a **mandatory, release-build hard-error** split-time check that every decl of a symbol defined in another partition carries exactly its owner's `eco-cap-*` set (presence and equality: the global premise of §4.3); per-partition `CapHoistDecisions`; copy cleanup; the value-eq decl copied wherever its marker is | Master gates; summed per-partition census == single-module census (counting owned functions only); fixture: a split with one decl's `eco-cap-covered` deleted must abort at the split |
| S7 | Invariant text (§10) | CSV updated in the same change |
| S8 (opt) | R3′: budget-0 callees transparent in Phase D | Its own loop step; output change; judged on wall time |

## 9. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| A wrong marker-table entry (e.g. list-tail as leaf) covers an allocating function | heap corruption | §4.3 runs on post-expansion IR, so it becomes a build error; S2 asserts at each expansion; fixture (c) |
| 02's stamps make an LLVM Phase A skip a covered callee's budget | heap corruption | R1 ordering; R2 assert; fixture (b) |
| Stale or smaller budget, or a missing covered bit, on a cross-partition decl | heap corruption | Mechanical copy from the owner, plus the **mandatory** split-time presence-and-equality check (S6). §4.3 does **not** catch it: the caller's check uses the same wrong decl value, and the owner's check never sees the caller |
| Marker-free partition has no plan stamp and falls into compute mode | heap corruption | The stamp lives on the module, not the marker decl; `eco-cap-*` present without a stamp is an error; fixture (e) |
| Exe plan applied to a `.o`/`.so`/JIT output | heap corruption | `exe=` in the stamp; linkage assert (§4.1); fixture (g) |
| MLIR reach superset (03) → spurious address-taken | lost coverage, validate noise | M7; 03's DCE must match GlobalDCE on functions and globals |
| `addressof` emulation wrong for mismatched FTy | either direction | Validate diff; mirror `getCalledFunction` and `hasAddressTaken` exactly (E5/E7) |
| Env drift between the MLIR pass and the backend | wrong K/M2 | Plan stamp + hard mismatch error |
| `$cap` copy order changes AlwaysInliner results | identity, not soundness | M5; accepted as a deterministic change at the split; recursive-tax gate |
| Two implementations of Phase A drift | validate noise | Shared B/C core; the LLVM front end stays as the §4.3 verifier, so it is exercised every build |
| Fixtures checking `attributes #N` in `-emit=llvm` | test churn | Strip after use (§5.4); `-emit=mlir-llvm` CHECKs need a review (`grep passthrough test/codegen`: 6 files) |
| Sat bracket without a non-leaf generic call (latent today) | heap corruption, pre-existing | Q3; the final-view table column makes 02 conservative |

## 10. Invariant amendments (S7)

- **CGEN_074:**
  - A–C are computed by `EcoCapHoistPlan` (MLIR) and carried as `eco-cap-*` passthrough.
  - `applyCapacityHoisting` in plan-given mode verifies them locally (§4.3) and never
    recomputes eligibility.
  - R1 classification order.
  - §2.6(a) is per-partition.
- **HEAP_034:** expansion runs per partition *after* splitting, still before the `$cap` prepass
  and every RS4GC flavour.
- **CGEN_072:** placement moves (02); add "a covered function is also gc-leaf; classifiers test
  coverage first".

## 11. Open questions

- **Q1.** Does translation keep unreachable MLIR blocks (M4)? Upstream
  `getBlocksSortedByDominance` starts an RPO from every block not yet visited, so it should
  include them. Confirm with a fixture. If it does not, the E2 emulation must drop them
  instead.
- **Q2.** Who owns the two-column marker table: `EcoToLLVMRuntime` or a new header next to
  `EcoBackend.cpp`? It must be shared with 02.
- **Q3.** Should the hoisting view treat `__eco_sat_begin` as may-GC (conservative)? That is
  identical to today only if every bracket encloses a non-leaf call. M3 can confirm, and then
  the more conservative entry is free.
- **Q4.** Should eligibility move from linkage to 03's explicit "all callers known" fact? That
  would recover M1 on `.o`/`.so` outputs, but it is an output change and a separate step.
- **Q5.** Should a run be allowed to span a marker-expansion diamond (Phase D in MLIR)? It
  would be fewer ensures, but a deliberate output change. Out of scope here.
- **Q6.** Does `passthrough` with key=value pairs survive translation onto *declarations*?
  gc-leaf (a bare string) does; key=value needs a one-line fixture in S3.

# Part II: implementation specification

Part II is what an engineer implements. It resolves every open item in Part I that blocks
building, using the plan-00 measurements. Where Part I and Part II disagree, Part II wins.

## P0. Scope

**In scope**, all buildable on today's single-module pipeline, where they must produce a
byte-identical ELF:
- I1, the shared core;
- I2, the marker table;
- I3, the MLIR planning pass;
- I4, driver plumbing;
- I5, plan-given mode in the backend, with every Part I check;
- I6, validate mode;
- I7, the fixtures and gates;
- I8, the invariant text.

**Out of scope here:**
- **S6** (split-time attribute copying, `$cap` copies and the equality check) is built as part
  of the master plan's split milestone (M6). No split exists yet, so there is nothing to call
  it from. I5 already makes every per-function check read callee facts from attributes,
  including on declarations, so S6 only adds the copying and the equality check.
- **S8 / R3′** is an optional output change, judged separately.

**Facts from plan 00** that settle open questions:
- **Q1:** translation keeps every block (0 mismatches). There are no unreachable blocks today.
- **TLI-only leaf calls are 0,** so the TLI arm needs no emulation beyond a small libm name list.
- **The match is exact** when the MLIR side uses exe-closed-world eligibility, with
  address-taken counted from **reachable** referrers only, and K = 512.
- **Q3:** sat markers in the hoisting view are leaf (exact match). The final view is 02's
  concern.

## P1. File and module layout

| File | New or changed | Library | Contents |
|---|---|---|---|
| `runtime/src/codegen/Passes/EcoCapHoistCore.h/.cpp` | new | EcoPasses | env readers (moved from `EcoBackend.cpp`): `capHoistMode()`, `capHoistMaxBytes()`, `capHoistFoldOwnMarkers()`, `gcFreeLeafMode()`. `struct CapHoistNode`; `capHoistSolve()` (Phase B Tarjan + C coverage); plan-stamp encode and parse; attribute names |
| `runtime/src/codegen/Passes/EcoMarkerFacts.h` | new | header-only | the marker table: hoisting-view override, headroom-breaker names, cursor / scratch / value-eq rows, trusted gc-leaf declaration names |
| `runtime/src/codegen/Passes/EcoCapHoistPlan.cpp` | new | EcoPasses | the MLIR pass `createEcoCapHoistPlanPass(options)` |
| `runtime/src/codegen/Passes.h` | changed | | pass factory declaration |
| `runtime/src/codegen/EcoPipeline.h/.cpp` | changed | | `EcoPipelineOptions{capClosedWorld, capRoots}`; add the pass as the last pass of `buildEcoToLLVMPipeline` |
| `runtime/src/codegen/EcoBackend.h/.cpp` | changed | | `EcoBackendJob::capClosedWorld`. `applyCapacityHoisting` returns `llvm::Error`, uses the core for B/C, and gains plan-given mode, validate mode, the §4.3 verification, R1/R3, §2.6 on declarations, the trusted-set assert, and the attribute and flag strip |
| `eco-boot.cpp`, `EcoNativeDriver.cpp` | changed | | compute closed-world and roots **before** `runPipeline`; pass them to both the pipeline and the job |
| `runtime/src/codegen/CMakeLists.txt` | changed | | add the two new `.cpp` files to the EcoPasses source list |
| `test/codegen/caphoist_plan_*.mlir` | new | | fixtures (a)–(h), plus a positive and a validate fixture |
| `design_docs/invariants.csv` | changed | | CGEN_074, HEAP_034, CGEN_072 text |

## P2. I1: the shared core (`EcoCapHoistCore`)

```text
namespace eco::caphoist {
enum class Reason : uint8_t { None, Loop, Cycle, Budget, Other };
struct Node {                       // one defined function
  uint64_t ownBytes = 0;
  bool top = false; Reason reason = Reason::None;
  bool eligible = false, selfEdge = false;
  std::vector<std::pair<uint32_t,bool>> callees; // (node index, inLoop)
  uint64_t budget = 0;              // output (valid iff !top)
  bool covered = false;             // output
};
void solve(std::vector<Node> &nodes, uint64_t K);   // Phase B + C, exactly today's rules
}
```

- `solve` is a verbatim lift of today's Phase B (iterative Tarjan, `contributionOf`, the cycle
  and non-cycle rules) and Phase C (`covered = !top && budget > 0 && eligible`).
- The census counters (`excl_*`) stay in `EcoBackend.cpp`. They are computed from the nodes
  after `solve`.
- **LLVM front end:** `applyCapacityHoisting` Phase A still fills `CapHoistInfo`. It then copies
  each record into `Node` (ordered as `defined`, with callee `Function*` mapped to its index),
  calls `solve`, and copies `top`/`reason`/`budget` back. Every later phase is unchanged.
- **Gate:** byte-identical ELF and an identical `[caphoist]` line on the self-compile.
- **Env readers:** move them (and `envNamed`, if used) into the core `.cpp`. Keep their exact
  semantics and the `static const` caching. `EcoBackend.cpp` calls them through the header.

## P3. I2: the marker table (`EcoMarkerFacts.h`)

```text
namespace eco::markers {
enum class Hoist : uint8_t { FromDecl, Leaf, NotLeaf };
// Hoisting view: how LLVM Phase A (after expansion steps 1-7) classifies a call to `callee`.
Hoist hoistView(StringRef callee, bool valueEqLeaf);
bool isHeadroomBreaker(StringRef callee);   // "eco_gc_alloc_region_fast", "eco_alloc_*_fast"
bool isCursorMarker(StringRef);             // __eco_list_cur*_inline, __eco_list_step_{node,idx}_inline, eco_list_pos_view
bool isScratchHelper(StringRef);            // eco_scratch_mark / _push_boxed / _push_scalar
bool isLibmLeaf(StringRef);                 // TLI arm: asin acos atan atan2 sin cos tan exp log log2 log10 pow sqrt floor ceil trunc round fabs fmod ldexp
bool isTrustedLeafDecl(StringRef);          // R1 gap: names allowed to be gc-leaf without eco-cap-*
}
```

**Rows of `hoistView`:**

| Callee | Result | Reason |
|---|---|---|
| `__eco_list_tail_inline` | `NotLeaf` | expands to `eco_list_tail_hybrid`, which is not leaf |
| `__eco_value_eq` | `Leaf` iff `valueEqLeaf`, else `NotLeaf` | `valueEqLeaf = ECO_VALUE_EQ_GCLEAF=1 \|\| (module has a gc-leaf "Elm_Kernel_Utils_equal" declaration)`, evaluated on the module being planned |
| cursor markers | `Leaf` | expand to leaf-only code; their MLIR declarations lack passthrough |
| scratch helpers | `Leaf` | stamped by the backend before hoisting |
| anything else | `FromDecl` | the callee declaration's passthrough decides |

`isTrustedLeafDecl` is true for names starting `eco_`, `__eco_`, `Elm_Kernel_`, `Eco_Kernel_`,
`llvm.`, plus `isLibmLeaf`.

The LLVM side uses the same header in two places:
- `isHeadroomBreaker` replaces the local copy;
- the post-expansion assert (P6.6) checks the table against the expanded module.

## P4. I3: the planning pass `EcoCapHoistPlan` (MLIR, llvm dialect)

**Placement:** `pm.addPass(createEcoCapHoistPlanPass(opts))` as the **last** pass of
`buildEcoToLLVMPipeline`, after `EcoTailConversions`. The module is then pure llvm dialect.

**Options:**
- `closedWorld` (bool);
- `roots` (MLIR names; `eco_main` maps to `main`).

**Algorithm:**
1. **Gate.** Unless `capHoistMode()==On && gcFreeLeafMode()==Stamp`, return without changing
   anything. LLVM then runs compute mode exactly as today.
2. **Pre-planned input.** If the module already has an `eco-cap-plan` module flag (a
   hand-written or re-lowered fixture), return without changing anything. If any `llvm.func`
   carries an `eco-cap-*` passthrough and there is no flag, emit an error ("eco-cap attributes
   without a plan stamp") and `signalPassFailure`.
3. **R2.** Any defined `llvm.func` with a `gc-leaf-function` passthrough is an error ("defined
   function already gc-leaf before planning").
4. **Index.** Symbol nodes for every top-level op with a symbol name. Functions are defined
   iff they have a body.
5. **Reference collection,** in parallel per top-level op, as in plan 00's census:
   - every `SymbolRefAttr` in the op's attribute dictionary;
   - `SymbolTable::getSymbolUses(op)`;
   - every `llvm.mlir.addressof` whose use is anything other than operand 0 of an `llvm.call`
     whose callee function type equals the target's type is an **address take**. This includes
     uses inside global initializers. An `addressof` with no uses is not a take.
6. **Closed world** (`closedWorld == true`):
   - BFS over all references from `roots` plus every non-symbol top-level op;
   - `addrTaken(f)` = some **reached** referrer takes `f`'s address;
   - `local(f)` = `f ∉ roots`.

   **Open world:** `addrTaken(f)` = any referrer takes it; `local(f)` = the MLIR linkage is
   `Internal` or `Private`.
7. **Phase A,** in parallel per defined function. This replicates `EcoBackend.cpp` Phase A:
   - **Cycles:** an entry-rooted SCC walk over blocks; a block is in a cycle if its SCC has
     size > 1 or a self-loop.
   - **Per `llvm.call`:**
     - resolve the callee: the direct symbol, or `addressof @g` plus a type match (else
       indirect);
     - marker `__eco_alloc_inline`: the size comes from the `llvm.mlir.constant` operand; in
       a cycle → ⊤ Loop; else `ownBytes += size`;
     - breaker (direct) → ⊤ Other;
     - hoisting view `Leaf`, or (`FromDecl` and the callee declaration has gc-leaf), or a
       libm declaration → transparent;
     - a mismatched-type `addressof` call to a gc-leaf declaration → transparent (the
       called-operand arm);
     - a direct call to a defined, non-interposable function → callee edge `(idx, inLoop)`,
       `selfEdge` if it is the function itself;
     - otherwise → ⊤ Other.
   - `eligible = !interposable && !addrTaken && local`. Interposable means linkage weak,
     linkonce, extern_weak or common.
8. `caphoist::solve(nodes, capHoistMaxBytes())`.
9. **Stamp** each defined function's `passthrough` (appended; existing entries kept):
   - `["eco-cap-budget","<N>"]` if not ⊤;
   - else the string `"eco-cap-top"`;
   - plus `"eco-cap-covered"` if covered.
10. **Module flag.** `llvm.module_flags` gets
    `#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=<K>;m2=<0|1>;cw=<0|1>">`.
    If a `llvm.module_flags` op already exists, append to its flag list.
11. `ECO_CAPHOIST_PLAN_STATS=1` prints
    `[caphoist-plan] defined=… covered=… top=… budget0=… time=…s`.

## P5. I4: driver plumbing

| Driver | closedWorld | roots | Job `capClosedWorld` |
|---|---|---|---|
| `eco-boot` exe output | true | `main`, `__eco_init_globals` | true |
| `eco-boot` obj with `--internalize-keep=L` | true | L, with `eco_main` mapped to `main` | true |
| `eco-boot` other (obj, `.so`/`.node`, `--emit=llvm`) | false | – | false |
| `EcoNativeDriver`: not `.o` and not shared | true | `main`, `__eco_init_globals` | true |
| `EcoNativeDriver` otherwise | false | – | false |
| `ecoc`, `EcoRunner` | false | – | false (default) |

`eco-boot` currently computes `emitObjOnly`/`isExecutable` after `runPipeline`. Hoist that
computation (it depends only on `emitAction` and `output`) above the `runPipeline` call, and
pass `EcoPipelineOptions` into `runPipeline`. `EcoNativeDriver` computes the same from
`outputPath` before its `runPipeline`.

## P6. I5: plan-given mode in `applyCapacityHoisting`

The signature becomes `Error applyCapacityHoisting(Module&, CapHoistMode, CapHoistDecisions*,
bool allowTls, bool closedWorld)`. The caller in `runEcoBackend` propagates the `Error`.

1. **Mode selection.**
   - Read the module flag `eco-cap-plan` (`m.getModuleFlag`, an `MDString`).
   - If present: parse it; require `K == capHoistMaxBytes()`, `m2 == foldOwn` and
     `cw == closedWorld`; otherwise return the error `plan stamp mismatch (...)`. That is
     **plan-given**.
   - If absent and any function has an `eco-cap-*` attribute: error.
   - If absent otherwise: **compute mode** (today's code).
   - **Compute mode R2 mirror:** if any *defined* function has `gc-leaf-function`, error
     ("compute-mode hoisting on a module with stamped definitions").
2. **Facts.** `struct CapFact { bool has, top, covered; uint64_t budget; }`, read from the
   string attributes of **every** function, definitions and declarations. A malformed budget
   attribute is an error.
3. **Trusted-set assert (R1 gap).** Every *declaration* with `gc-leaf-function` and no
   `eco-cap-*` attribute must satisfy `markers::isTrustedLeafDecl`; otherwise error.
4. **Local Phase A (the §4.3 verification).** For each definition, run today's Phase A loop
   with the **R1 order**:
   - marker;
   - breaker;
   - **callee carries eco-cap facts → callee edge** (even if it also carries gc-leaf, and even
     if it is a declaration);
   - `callsGCLeafFunction` → transparent;
   - defined non-interposable → edge (only reachable for a definition without facts, which is
     an error in plan-given mode);
   - else ⊤.

   Then, with `contrib(g) = g.covered ? g.budget : (!g.top && g.budget == 0 ? 0 : TOP)`:
   - **Covered f:**
     - not ⊤ locally;
     - no edge has `contrib == TOP`;
     - no `inLoop` edge with `contrib > 0`;
     - `ownBytes + Σ contrib ≤ f.budget` (`==` under validate);
     - `hasLocalLinkage()`.
   - **Budget-0 f:** not ⊤ locally; `ownBytes == 0`; every `contrib == 0`.

   Any failure: error naming the function and the rule.
5. **Install the plan.**
   - `covered` = definitions with the covered fact;
   - `info[f].budget/top` from the facts.
   - Phase D, D2, §2.6 and Phase E then run on these.
6. **Post-expansion table assert.** For every call whose callee name is
   `eco_list_tail_hybrid`, `eco_list_head_hybrid`, `Elm_Kernel_Utils_equal`, a scratch helper
   or `__eco_resolve_fwd`: the result of `callsGCLeafFunction` must equal the leafness the
   table implies for the marker that produced it. That is: list-tail → non-leaf; list-head →
   leaf; `Utils_equal` → `valueEqLeaf`; scratch → leaf; `resolve_fwd` → leaf. Otherwise error
   ("marker table disagrees with expansion").
7. **R1 in Phase D, D2 and §2.6 (both modes, a no-op without facts).**
   - **Phase D:** if the callee has facts: covered → run element (budget from the fact); else
     → breaker (R3). Otherwise today's rules.
   - **D2 re-walk:** an element is acceptable iff it is an own marker, or a covered-fact
     callee in `covs`, or (no facts, not a breaker, and `callsGCLeafFunction`).
   - **§2.6(a):** iterate every function, **declaration or definition**, that is covered
     (facts in plan-given mode, `covered` in compute mode). Each user must be a `CallInst`
     with `getCalledFunction() == f`, inside a covered definition or recorded as a run
     member.
   - **§2.6(b):** a callee with facts is admissible iff covered or (`budget == 0 && !top`).
     Without facts, today's rule applies.
8. **Strip** after `expandInlineAllocs`: remove the `eco-cap-*` string attributes from every
   function, and remove `eco-cap-plan` from `llvm.module.flags`. The ELF and `-emit=llvm`
   dumps are then unchanged.

## P7. I6: validate mode (`ECO_CAPHOIST_VALIDATE=1`)

- In plan-given mode, before step 5, run today's compute-mode Phases A–C on the same module.
  Ignore all facts and use today's classification order. This is safe because no definition is
  gc-leaf yet: R2 holds until plan 02 lands.
- Compare per definition: `top`, `budget` (when not ⊤) and `covered`. Print the first 20
  differences, then the error `validate: N plan/compute differences`.
- The §4.3 inequality uses `==`.
- Prints `[caphoist-validate] compared=… diffs=0`.

## P8. I7: fixtures and gates

**Fixtures** (`test/codegen`, llvm-dialect input with a forged plan, run with `%ecoc %s
-emit=llvm`; `ecoc` is open world, so the stamp says `cw=0`):

| Fixture | Content | Expect |
|---|---|---|
| `caphoist_plan_decl_callee.mlir` (a) | internal `@f` with two markers, calling a covered **declaration** `@g` (budget 48) | ensure with `need = own + 48`; `eco_ensure_nursery_slow` present |
| `caphoist_plan_gcleaf_covered.mlir` (b) | same, but `@g` also carries `gc-leaf-function` | the ensure still includes 48 (R1) |
| `caphoist_plan_listtail_mistabled.mlir` (c) | covered internal `@f` calling `__eco_list_tail_inline` | `not`; message `covered function` … `non-transparent` |
| `caphoist_plan_stale_k.mlir` (d) | stamp `K=1024` | `not`; `plan stamp mismatch` |
| `caphoist_plan_markerfree.mlir` (e) | a function with no markers calling a covered declaration | ensure present |
| `caphoist_plan_loop_covered.mlir` (f) | covered `@f` calling covered `@g` inside a loop | `not`; `in a loop` |
| `caphoist_plan_external_covered.mlir` (g) | covered **external** definition | `not`; `local linkage` |
| `caphoist_plan_untrusted_leaf.mlir` (h) | `@weird` declaration with gc-leaf and no `eco-cap-*` | `not`; `untrusted gc-leaf` |

- **Positive end-to-end:** the existing suite already exercises the pass on every eco-dialect
  fixture, where `ecoc` is open world: wrappers and `$sat` entries are internal and plan-able.
- **Gates,** in order, `ulimit -c 0`:
  1. **Byte-identical ELF:** lower `eco-compiler-boot.mlir` with the pre-change
     `eco-boot-native` (saved copy) and with the new one; `cmp`.
  2. **Validate on the self-compile lowering:** `ECO_CAPHOIST_VALIDATE=1`, 0 differences.
  3. **`check`** (unit + JIT E2E + codegen fixtures), once with `ECO_CAPHOIST_VALIDATE=1`
     exported. Must pass the same count as before plus the new fixtures.
  4. **`stress`** with `ECO_CAPHOIST_VALIDATE=1`.
  5. **`run-aot-e2e`** with `ECO_CAPHOIST_VALIDATE=1`. This is the closed-world AOT path.
     893/895 is the known baseline (FlagsRecordTest, PortEchoTest).
  6. **`elm-tests`:** unchanged (no front-end change), skipped.
  7. **Bootstrap:** Stage 4b and 8c fixed points; Stage 9b succeeds.
  8. **Lowering time:** record the `capacity-hoist analysis` phase and the new MLIR pass time.

## P9. I8: invariant text

- **CGEN_074:**
  - Phases A–C are computed by `EcoCapHoistPlan` (MLIR) when hoisting is on; the results
    travel as `eco-cap-budget`/`eco-cap-top`/`eco-cap-covered` passthrough plus the
    `eco-cap-plan` module flag.
  - `applyCapacityHoisting` in plan-given mode never recomputes eligibility. It verifies
    every definition locally (§4.3), classifies callees with eco-cap facts before gc-leaf
    (R1), checks §2.6(a) on covered declarations, and strips the attributes after
    `expandInlineAllocs`.
  - Compute mode remains for modules without a stamp (census, `ECO_ALLOC_HOIST` arms,
    hand-written IR).
- **HEAP_034:** unchanged placement. Add: "in plan-given mode the covered set comes from the
  stamped attributes."
- **CGEN_072:** add: "A covered function may also carry gc-leaf (plan 02); every classifier
  tests eco-cap facts before gc-leaf (R1)."

## Implementation results (2026-10-02)

All of I1–I8 built as specified, with two deviations found by the gates:

- **Unplanned definitions.** The JIT (`EcoRunner` → MLIR `ExecutionEngine`) synthesizes
  `_mlir_*` packed-interface wrappers *after* the plan pass, so plan-given mode sees
  definitions with no facts. They are installed as ⊤ (never covered, never budget-0), which
  is conservative. Validate mode skips them and reports them as `unplanned=N` instead of
  counting them as differences.
- **Forged-plan fixtures vs validate.** Fixtures (a)–(h) deliberately carry plans that
  disagree with compute mode, so they must not inherit a gate-wide `ECO_CAPHOIST_VALIDATE=1`.
  The codegen harness gained a `// UNSETENV: NAME` directive (subprocess path,
  `test/codegen/CodegenIsolatedTest.hpp`), and every `caphoist_plan_*.mlir` uses it.

Gates (`ulimit -c 0`):

| # | Gate | Result |
|---|---|---|
| 1 | Self-compile ELF vs pre-change `eco-boot-native` | byte-identical |
| 2 | Validate on the self-compile | compared 75,775, diffs 0 |
| 3 | `check` with validate | 2014 passed / 0 failed (2006 + 8 fixtures); 1234 validated modules, 16,928 compared, 0 diffs, 12,879 unplanned JIT wrappers |
| 4 | `stress` with validate | 101 / 101 |
| 5 | `run-aot-e2e` with validate | 899 / 901; the 2 failures are the known FlagsRecordTest and PortEchoTest |
| 6 | `elm-tests` | skipped (no front-end change) |
| 7 | Bootstrap | 4b and 8c fixed points hold, 9b OK (7 min 03 s; Stage 5 already current) |
| 8 | Lowering time (Stage 6) | `EcoCapHoistPlanPass` 0.61 s (MLIR, parallel scan); `capacity-hoist analysis (serial)` 1.00 s |

Self-compile plan census: `defined=98163 covered=16509 top=68603 budget0=5152 closed_world=1`.

## Adversarial review (2026-10-02)

The review re-checked every citation against `runtime/src/codegen` at HEAD. The line
numbers in §1, §2.4, §3 and §4.1 hold (Phase A 2957, B 3042, C 3199, D 3230, D2 3307,
§2.6(a/b/c) 3427/3445/3481; `runEcoBackend` 3651–3747). The stale
`EcoToLLVMClosures.cpp:1334` comment is confirmed: `runCapInlinePrepass` (3567–3647) has no fold.
The issues below are listed by severity. Each one is fixed in place.

| # | Issue | Evidence | Fix |
|---|---|---|---|
| A1 | **The §4.3 induction was stated as needing "no global view".** It silently assumed that decl attributes equal the owner's. A stale-smaller budget passes the caller's check (it uses the same wrong value) and the owner's check (it never sees the caller). The §9 row claiming §4.3 "catches a mismatch at the caller" was false | Phase B/D read callee budgets only through `contributionOf` / `info.find(callee)` (3069, 3286); a partition has nothing else to compare against | §0.2, §4.3 premise stated; S6 check made mandatory, release-build, presence and equality; §9 row rewritten |
| A2 | **"A missing copy can only fail safe or fail loud" was false.** If owner `g` is covered, its markers expand unchecked (`isUnchecked`, 1397). A non-covered caller in another partition that sees `g` as ⊤ breaks the run and emits no ensure. Today's §2.6(a) iterates only *defined* covered functions (3436), so no partition checks that call | 1397, 3436–3443 | §4.2 corrected; §2.6(a) extended to covered **decls** (§4.1); R1 gap noted (a decl stripped of all `eco-cap-*` but keeping gc-leaf reads as a plain leaf, the same as 02 O1); S6 fixture |
| A2b | **Cross-plan alignment with 02 (F11, O1).** A gc-leaf decl stripped of all `eco-cap-*` reads as a runtime decl, so the callee becomes transparent. Separately, compute-mode LLVM hoisting on a module that already has stamped definitions reopens the R1 hole | 02 §3 O1, F11, review R2 | R1 now requires 02's trusted-set assert (a gc-leaf decl without `eco-cap-*` must be a runtime, kernel or expansion name). R2 mirrored: compute-mode `applyCapacityHoisting` refuses stamped definitions. 'Generated with gc-leaf but neither covered nor budget 0' is a hard error |
| A3 | **The plan stamp on the `__eco_alloc_inline` decl misses marker-free partitions.** They fall back to compute mode, see covered decls as ⊤, and emit no ensure: heap corruption. The decl is also erased by `expandInlineAllocs` (1680) and by the MLIR unused-decl strip | `EcoToLLVM.cpp:601–663`; `EcoBackend.cpp:1509–1511` | §5.2: module flag or `EcoBackendJob`; "`eco-cap-*` without stamp" is an error; fixture (e) |
| A4 | **An exe-assumption plan on a non-exe output is unsound and was not discussed.** The drivers learn the output kind after the MLIR pipeline. Plan-given mode never recomputes eligibility, so an externally linked covered function would go unnoticed | `EcoNativeDriver.cpp:88,236`; `eco-boot.cpp:385,813` | §1, §6 plumbing note; `exe=` in the stamp; linkage-sanity assert (§4.1); fixture (g) |
| A5 | **§4.3 said "in-loop callees contribute 0".** Read literally, that admits a covered `f` calling a covered `g` in a loop: unbounded bumps under one reservation | Phase B makes that ⊤ (3172) | Rewritten as "must contribute 0, else fail"; fixture (f) |
| A6 | **The §4.3 budget-0 rule lacked "no ⊤ reason".** A forged or stale `budget=0` on a GC-ing function would pass, and §2.6(b) (3462) and Phase D would admit it as GC-free | 3462–3468 | Clause added |
| A7 | **Cursor markers are not gc-leaf in MLIR.** §2.2 listed them as "gc-leaf, transparent on both sides". The raw MLIR view is conservatively wrong (lost precision and validate diffs, not unsoundness), because they expand into leaf-only diamonds. Confirmed independently by the 02 reviewer | `EcoListCursor.cpp:110` (`ensureFn`, no passthrough); 02 O2 | §2 table and §2.2 row split; table override required; M3 counts them |
| A8 | **The value-eq description was wrong.** The MLIR runtime decl `Elm_Kernel_Utils_equal` is unconditionally gc-leaf, but it is stripped when unused. The expansion then mints a non-leaf decl, so leafness depends on module contents and differs per partition | `EcoToLLVMRuntime.cpp:940`; `EcoBackend.cpp:2385–2393` | §2.2 and §2.3 corrected; the split copies the decl (S6) |
| A9 | **`getOrInsertFunction` type mismatch was not emulated.** An expansion callee whose requested FTy differs from the existing decl becomes `getCalledFunction()==nullptr`, which is ⊤ in Phase A | `InstrTypes.h:1348` | §2.2 note; S2 assert; M3 |
| A10 | **The TLI arm of `callsGCLeafFunction` depends on the triple,** which is set after translation by `createEcoTargetMachine`; the MLIR module has none | `EcoBackend.cpp:1144, 2953` | §2.4 note |
| A11 | **Wrong or unsupported claims.** 12 marker sites (actually 13). "Most `$cap`s are address-taken" (the 3,250 figure is all functions). R3′ "no non-leaf calls" (budget-0 functions call other budget-0 functions). "⊤ ∧ GC-free empty" (`isInterposable` is ⊤ with no call). "Strict" inequality (it is ≤; the cycle argument still holds by summation) | as cited | Fixed in place |
| A12 | **`$cap` copies reference the owner's internal functions and private globals,** which need external visibility once inlined. Available_externally copies also run §4.3, D and §2.6 | 03 finding 4; `isDeclaration()` semantics | §4.4 bullets |
| A13 | **Re-lowering `-emit=mlir-llvm` input** would run `EcoCapHoistPlan` over existing attributes | — | Idempotence rule (§5.3) |

**Checked and found sound:**
- **Marker movement by the `$cap` prepass.** Inlining happens after `expandInlineAllocs`, and a
  covered call site is always a run element or sits inside a covered caller. An in-loop call
  in a covered caller is excluded by Phase B.
- **CFG-cycle invariance across steps 1–7.**
- **`addressof` translation.** A dead `addressof` creates no LLVM use.
- **`expandSatMarkers` after hoisting.** The bracket always encloses the non-leaf
  `eco_closure_call_saturated*` call (`EcoToLLVMClosures.cpp:2420–2455`), so no run spans it.
- **Allocation grouping.** Mixed groups are ⊤ by name. With
  `ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0`, all-inline groups are too.
- **Per-partition `uncheckedMarkers`.** These need only local Phase D plus attributes, as §4.1
  says.

**Residual concerns:**
- The §4.3 net is only as strong as the S6 split check. The split check is the single
  point of failure for A1/A2 and deserves its own negative fixtures and a validate-build
  cross-check against the owner's definitions.
- Order dependence in AlwaysInliner on nested `$cap` chains (§4.4) is unmeasured (M5).
- The value-eq row is module-content-dependent. Any future marker whose expansion reuses an
  MLIR runtime decl that the strip might remove has the same hazard. S2's per-expansion
  assert should check leafness *after* `getOrInsertFunction`, not just the name.
- 02's gc-leaf stamps on decls and 01's `eco-cap-*` must be copied by the same whitelist in
  one place (02 O4), so they cannot diverge.
