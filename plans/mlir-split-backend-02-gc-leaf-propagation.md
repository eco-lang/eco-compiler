# MLIR split backend 02: gc-free leaf propagation on the MLIR side

**Master plan:** `plans/mlir-split-backend.md`. **Status:** IMPLEMENTED 2026-10-02 (J1–J8;
results in "Implementation results" at the end of Part II). Specified 2026-10-02. Part I (§0–§9 plus its adversarial review) is the feasibility analysis; Part II
is the build specification. EcoSplit's attribute copy (step 6) is deferred to the master
plan's split milestone.

**Research:** `design_docs/mlir-level-partitioning-whole-program-steps.md` §4.
**Background:** `plans/gc-free-function-propagation.md` (CGEN_072/073),
`plans/capacity-check-hoisting.md` (CGEN_074), `plans/mlir-split-backend-01-cap-hoist-plan.md`.

Line numbers were read on 2026-10-02 and are approximate. Re-grep before editing.
`EB` = `runtime/src/codegen/EcoBackend.cpp`. `P/` = `runtime/src/codegen/Passes/`.

## 0. Verdict

The move is **feasible**, and it does not have to make GC safety weaker. But it is not the
"port one fixpoint" step the outline suggests. Seven findings change the design:

1. **01 and 02 swap places as consumers (critical).** Today hoisting runs before gc-free
   stamping and never sees a propagated stamp. Under the plan, the per-partition Phase D/D2
   run scan runs *after* 02 has stamped. That scan treats a `callsGCLeafFunction` callee as
   headroom-transparent. A stamped *covered* function makes unchecked bumps. So "gc-leaf"
   stops implying "allocates nothing". If the coverage attribute were missing, the result
   would be silent heap corruption, and no existing assert would catch it (§3 O1). The same
   hazard hits Phase A (and 01's §4.3 per-partition re-run of Phase A), not only D/D2, and
   it cannot be closed by attribute *presence* alone (review R1/R2).
2. **The marker table runs in both directions.** Some markers are declared gc-leaf but
   expand into a call that can GC. That much was known. The reverse case is new: the six
   list-cursor markers are declared **non**-leaf in MLIR (`P/EcoListCursor.cpp:103-111`)
   but expand into leaf-only diamonds. Trusting the declarations would make the result
   conservatively wrong, not unsafe.
3. **02 needs one bit from 01, not per-marker decisions.** Every function holding a
   marker that is not covered ends up with a slow call or an ensure call. A non-covered
   caller of a covered function always holds an ensure (§2.6(a), `EB:~3428`). So 02 needs
   only `eco-cap-covered` (§3 O3).
4. **Cross-partition consistency needs its own check.** The per-partition post-RS4GC
   assert already proves "no stamped body contains a statepoint" for each partition. It
   cannot prove that a gc-leaf *declaration* in partition P matches a stamped *definition*
   in partition Q. That join is the one global check the split adds (§4, F5).
5. **The proposed "local check" is mostly the post-RS4GC assert under another name.**
   It adds value only for functions without a GC strategy and for diagnostics (§4).
6. **The musttail argument is moot.** No LLVM `musttail` or `tail` kind is ever emitted:
   there is no `TailCallKind` anywhere in `runtime/src/codegen`, and
   `P/EcoToLLVMClosures.cpp:2941` only suppresses the safepoint marker.
7. **The time saved directly is small.** The LLVM fixpoint costs about 290 ms serial
   (`benchmarks/backend-opt-loop.md:230`, ten runs, 288–304 ms). The value of 02 is that
   the split cannot happen without it.

## 1. Today: code facts

### 1.1 Pre-RS4GC order in `runEcoBackend` (`EB:3651-3790`)

| # | Step | Line | Calls it introduces (leaf?) |
|---|---|---|---|
| 1 | `expandGetTagMarkers` | 2518 | `__eco_resolve_fwd` (leaf) |
| 2 | `expandListProjMarkers` head / tail | 2511-2516, 2056 | `__eco_resolve_fwd`, `__eco_slot_to_hptr` (leaf); `eco_list_head_hybrid` (leaf) / **`eco_list_tail_hybrid` (NOT leaf)** |
| 3 | `expandListCursorMarkers` (6 markers) | 2303, 2151 | `__eco_resolve_fwd`, slot barrier (leaf only) |
| 4 | `expandStringLenMarkers` | 2449 | `__eco_resolve_fwd` (leaf) |
| 5 | `expandValueEqFastPath` | 2373 | `Elm_Kernel_Utils_equal`: leaf **only if** its declaration survived with gc-leaf, or `ECO_VALUE_EQ_GCLEAF=1` (§3 O5) |
| 6 | scratch-helper stamp loop | 3670-3675 | stamps `eco_scratch_mark/push_boxed/push_scalar` (backend-only) |
| 7 | `expandInlineDerefs` | 1330 | `eco_follow_forward` (leaf, stamped at 1340-1343) |
| 8 | `applyCapacityHoisting` (01's LLVM home) | 3700 → 2949 | ensure diamonds: **`eco_ensure_nursery_slow` (NOT leaf)**; `eco_bump_state` (leaf) |
| 9 | `expandInlineAllocs` | 1506 | `eco_bump_state` (leaf, 1525-1534); **`eco_alloc_inline_slow` (NOT leaf)** unless the marker is unchecked (1577-1595) |
| 10 | `expandRootRangeOps` | 1726 | removes leaf calls (TLS) or keeps them; nothing new |
| 11 | `expandSatMarkers` | 1853 | **indirect** fast call `%sat(...)` (1980) → poison |
| 12 | `runCapInlinePrepass` (not at -O0) | 3737 → 3567 | AlwaysInliner on `$cap` ≤ 64 insts; strips `alwaysinline` afterwards |
| 13 | `propagateGcFreeLeafAttrs` | 3747 → 2740 | stamps definitions |
| 14 | RS4GC: serial (3785), deferred after -O2 (3822), workers (781-788, 1068-1071), or single-partition inline (3886) | | |

Under `--parallel-opt=cgu`, the cheap-IPO prologue (`runCheapModuleIPO`, `EB:499`; IPSCCP
plus GlobalDCE) runs **between** step 13 and the worker RS4GC. IPSCCP adds no calls and
drops no string attributes. GlobalDCE only deletes.

Note on step 11: the sat markers expand **after** hoisting, so the hoisting comment that
"all remaining GC hazards are real calls" is not literally true. It is harmless only
because the bracketed slow sequence always holds a non-leaf runtime call.

### 1.2 `propagateGcFreeLeafAttrs` (`EB:2740-2875`)

- **Function-level poison:**
  - `isInterposable()`;
  - a `LandingPadInst`;
  - any non-`CallInst` call base (invoke or callbr);
  - a call that is not leaf under `callsGCLeafFunction(cb, TLI)`, unless it targets a
    defined, non-interposable function;
  - in that last case, the call becomes a reverse edge instead (2765-2783).
- **Fixpoint:** an optimistic worklist. A cycle with no poison stays free.
- **Census:** counted before stamping. `ECO_GCFREE_LEAF_DUMP` writes the free set (2817).
  This is the natural oracle for validate mode.
- **Stamping:** survivors get `addFnAttr("gc-leaf-function")` (2826-2828).
- **TLI:** a standalone `TargetLibraryInfoImpl(triple)`.

### 1.3 How RS4GC decides (LLVM 21.1.8)

`llvm::callsGCLeafFunction` (`llvm/Transforms/Utils/Local.h:491`; semantics recorded in
`plans/gc-free-function-propagation.md` §1.4) returns leaf when any of these holds:
- **(a)** the call site has the string attribute `gc-leaf-function`. `CallBase::hasFnAttr`
  falls back to the callee read through `getCalledOperand()`, with **no function-type
  check**;
- **(b)** `getCalledFunction()` has the attribute. That lookup is null on a function-type
  mismatch;
- **(c)** the callee is an intrinsic other than statepoint, deoptimize or the
  element-unordered-atomic memcpy/memmove. The test is `getIntrinsicID() != 0`, so an
  `llvm.`-prefixed name LLVM does not recognise is **not** leaf, and (c) is reached only
  through `getCalledFunction()` (function type must match);
- **(d)** TLI recognises a libcall by name and prototype.

Other relevant facts:
- RS4GC processes a body if `F.hasGC()` is true. The GC name `eco-gc` is set at
  `P/EcoToLLVM.cpp:564`.
- `__eco_init_globals` has no GC strategy and is never processed.
- RS4GC strips only memory, nosync and nofree from prototypes, so string attributes
  survive.
- Eco never emits call-site gc-leaf attributes, so fact (a) only ever comes through the
  callee.

### 1.4 Post-RS4GC consumers (`runRS4GCAndMaybeFramePointers`, `EB:1178`)

- **Assert (1208-1221, stamp mode only):** a defined function with `gc-leaf-function`
  that contains a `GCStatepointInst` is a hard error. It runs inside every RS4GC flavour,
  so each worker checks exactly the partition it statepointed.
- **Frame pointers (CGEN_073, 1236-1282):** `frame-pointer=all` goes on any function
  that has a statepoint or a direct call to `eco_gc_push_stack_range`. It depends on the
  stamps only through whether statepoints are present.
- **EcoPtrIntVerify** (`P/EcoPtrIntVerify.cpp:57`, validation builds only, post-RS4GC):
  accepts a `ptrtoint ptr<1>` passed to a callee that `hasFnAttribute("gc-leaf-function")`.
  It reads the stamp on the callee *Function*, so a cross-partition declaration missing a
  copied stamp is a validation false positive, not a safety issue.

### 1.5 Every place a gc-leaf stamp is produced

| Producer | Side | Targets | Under the plan |
|---|---|---|---|
| `EcoRuntime::getOrCreateFunc(.., gcLeaf=true)` (`P/EcoToLLVMRuntime.cpp:122-150`), via `attachGcLeafPassthrough` (`P/EcoToLLVMInternal.h:839-856`) | MLIR | about 90 runtime declarations, including every `__eco_*` marker except the cursor markers (622, 647, 657, 688, 693, 880, 886, 952, …) and `Elm_Kernel_Utils_equal` (927-940, **unconditional**: it also survives `ECO_KERNEL_GCLEAF=0`, because `KernelFuncOpLowering`'s dedup path (`P/EcoToLLVMFunc.cpp:43-51`) can only *add* the stamp) | unchanged; leaf bits come from the shared table |
| `KernelFuncOpLowering`: `eco.gc_leaf` → passthrough (`P/EcoToLLVMFunc.cpp:48, 99`), gated by `ECO_KERNEL_GCLEAF` | MLIR | kernel externs (CGEN_072(f)) | unchanged |
| `eco_caf_promote` declaration (`P/EcoToLLVMGlobals.cpp:602-607`) | MLIR | one declaration | unchanged |
| `EcoListCursor::ensureFn` (`P/EcoListCursor.cpp:103-111`) | MLIR | six cursor markers, **no** gc-leaf | the table classifies them as leaf |
| `addFnAttr` inside expansions (`EB:1343, 1533, 2075-2086, 2172-2176, 2465, 2535, 3371`) | LLVM | runtime declarations created by `getOrInsertFunction` | unchanged; every partition expands its own markers |
| scratch helpers (`EB:3670-3675`) | LLVM | three `is_kernel` stubs from `P/EcoListTemplate.cpp:303-314` | move to MLIR (§5 step 2) |
| `ECO_VALUE_EQ_GCLEAF` (`EB:2391-2393`) | LLVM | `Elm_Kernel_Utils_equal` | the table decides; the expansion obeys it |
| `propagateGcFreeLeafAttrs` (`EB:2828`) | LLVM | generated definitions | **becomes `EcoGcFreePropagation` (MLIR)** |
| `eco.callee_gc_leaf` (`P/EcoMarkGCLeafCalls.cpp:75-91`) | MLIR, eco level | call sites, for EcoGCPrepare only | 02 must **not** feed it (CGEN_077(a) single channel) |

### 1.6 Order between 01 and 02 today

- **Hoisting comes first.** It never reads a propagated stamp: none exists yet, and
  Phase A, Phase D and §2.6(b) see only declaration stamps.
- **Hoisting predicts the gc-free result.** Its `contributionOf` comment and §2.6(b)
  (`EB:~3447-3480`) both rely on "budget 0 ⇒ CGEN_072 will stamp it".
- **gc-free reads hoisting's output:** unchecked bumps (no slow call) and ensure calls
  (poison). Hoisting adds about 6.1k stamps, 2,372 → 8,473 (`plans/capacity-check-hoisting.md:10`).
- **The `$cap` prepass reads stamps only in the barriers-off fallback**
  (`bodyIsGCCallFree`, `EB:2705`, used at about 3601).

## 2. Information flow: the facts RS4GC and the assert need at one call site

| Fact | Consumer | Producer today | Producer under the plan | Survives the split? |
|---|---|---|---|---|
| Caller `gc "eco-gc"` | RS4GC body selection | `P/EcoToLLVM.cpp:564` | same | yes; it travels with the owner's definition |
| Callee fn attr gc-leaf: runtime or kernel declaration | `callsGCLeafFunction` (b) | MLIR declarations plus LLVM `addFnAttr` | same, with leaf bits from the table | yes; each partition re-declares and re-expands its own |
| Callee fn attr gc-leaf: generated, same partition | (b) | LLVM fixpoint | MLIR passthrough on the definition | yes |
| Callee fn attr gc-leaf: generated, other partition | (b) | CloneModule / `deleteBody` keep definition attributes (`EB:781`, 1029) | **EcoSplit copies the passthrough onto the declaration** | only if copied; this is the new trust point (F5) |
| Direct vs indirect | (b), the fixpoint's edges | `getCalledFunction` (function type must match) | MLIR: `llvm.call @sym`, **plus** `addressof`→call with a matching type (01's rule) | yes |
| Intrinsic | (c) | translation of `llvm.intr.*` and `llvm.*` names | MLIR: intrinsic ops and `llvm.`-prefixed callees count as leaf | yes |
| TLI libcall | (d) | name + prototype | MLIR: **poison** (conservative). Measure M2c | yes |
| Marker expansion contents | fixpoint (post-expansion) | real IR at step 13 | the **table** (§5.1) | the expansion runs per partition, the same code |
| Unchecked marker / ensure presence | fixpoint | decisions from steps 8-9 | `eco-cap-covered` from 01 | the attribute is copied |
| Stamp on definition + statepoint presence | assert, FP | steps 13-14 | MLIR stamp + per-partition RS4GC | yes, per partition |

**Where an attribute can be lost or rewritten between stamping and RS4GC.**

- **Translation.** `passthrough` on declarations already carries every runtime and kernel
  stamp today, so the path is proven. `key=value` pairs (01) still need a fixture.
- **Steps 1-12 per partition.** None removes function attributes. AlwaysInliner leaves
  caller attributes alone.
- **Driver internalize + GlobalDCE** (`EB:1287`, exe paths, between translation and
  step 1): changes linkage external → internal and deletes functions. It never flips
  interposability, since no weak/linkonce/common linkage is emitted (grep of `Passes/`:
  none). It is a population difference (O6), not an attribute loss.
- **Prologue.** IPSCCP (`AllowFuncSpec=false`, `EB:535`, so it clones nothing) and
  GlobalDCE do not strip them. IPSCCP can turn an indirect call into a direct one, which only
  removes statepoints from calls to callees that are already stamped (sound).
- **Deferred flavour.** The full -O2 pipeline runs before RS4GC, but that flavour never
  combines with the split (`EB:3770`).
- **The only new hazard** is EcoSplit's attribute copy (§3 O4).

## 3. Obstacles found

**O1. A gc-leaf callee that bumps the nursery (critical, from the 01×02 coupling).**
- **Today:** Phase D (`EB:~3270-3300`) classifies each call in this order:
  1. marker;
  2. `isHeadroomBreaker`;
  3. covered callee → run element;
  4. `callsGCLeafFunction` → *transparent*;
  5. otherwise, a breaker.

  The D2 re-walk accepts `!isHeadroomBreaker && callsGCLeafFunction`. Today a defined
  callee is never stamped at this point, so every defined non-covered callee breaks the run.
- **Under the plan:** the scan sees 02's stamps.
  - A stamped *covered* callee whose coverage bit is missing (an EcoSplit copy bug, or a
    01/02 mode mismatch) becomes transparent. Its unchecked bumps are not counted in the
    run, so the bump passes `end`. That is heap corruption.
  - §2.6(a) iterates only the covered set, so it would see nothing.
  - Even when everything is correct, stamped budget-0 callees become transparent. Runs get
    longer and there are fewer ensures, so the **byte-identity gate fails**.
- **Phase A is hit too, and harder** (review R1). Phase A tests `callsGCLeafFunction`
  *before* the defined-callee edge (`EB:3026` vs 3028). A stamped covered callee becomes
  transparent, so the caller's **budget** drops the callee's bytes. The caller can then be
  covered itself, which makes §2.6(a) pass (the caller is covered) and §2.6(b) pass (the callee
  is covered). That is silent heap corruption. It applies to any LLVM-side Phase A run on
  stamped IR: the validate twin, 01's §4.3 per-partition Bellman re-run, and the full
  `applyCapacityHoisting` if it ever runs after 02 has stamped (for example plan-given mode
  disabled while MLIR stamping is on).
- **Mitigation (corrected; it must match 01 §3 R1/R3):**
  - Every classifier (Phase A, D, D2, §2.6(b), 01 §4.3) decides a **generated** callee from
    its `eco-cap-*` attributes *before* `callsGCLeafFunction`: covered → element / budget;
    anything else → **breaker** (R3, today's decision for an unstamped callee). Treating a
    budget-0 callee as transparent is R3′: sound, but an output change, so not in the
    identity step. (The draft said "transparent only when budget 0". That contradicts the
    byte-identity argument two bullets up.)
  - "Generated" must **not** be inferred from attribute presence. A cross-partition decl
    that lost its `eco-cap-*` copy but kept `gc-leaf` would read as a runtime declaration →
    transparent → the O1 hole again. Rule: a gc-leaf declaration with no `eco-cap-*` attribute
    must be in the trusted set (the shared runtime-declaration table ∪ `Elm_Kernel_*` / kernel
    stubs ∪ expansion-created names). Otherwise it is a **hard error** in every partition
    (cheap: one pass over declarations). EcoSplit always writes `eco-cap-top` or a budget
    on every generated decl, so absence means "not generated".
  - A generated callee with gc-leaf that is neither covered nor budget 0 is a hard error (01's
    "⊤ ∧ GC-free is empty" premise).
  - The full LLVM `applyCapacityHoisting` (non-plan-given) must refuse to run on a module in
    which any *definition* already carries gc-leaf (01's R2, mirrored on the LLVM side).
- **Effect:** this restores today's decisions exactly and closes the hole. It must land
  in 01's plan-given mode, and 02 step 5 depends on it.

**O2. Cursor markers are non-leaf in MLIR** (`P/EcoListCursor.cpp:110`).
- Every function with a cursor loop would be poisoned, and so would its callers.
- The table must override the declaration in both directions.
- 01's Phase A has the same problem (⊤), so the table must be shared.

**O3. 02's dependence on 01 is exactly the covered set.** Argued from the code:
- `CapHoistDecisions::isUnchecked` (`EB:1397`) makes every marker of a covered function
  unchecked.
- A covered function has no markers in CFG cycles, since those are ⊤.
- A non-covered function with any marker either keeps a checked diamond (slow call) or
  has its markers folded into a run (ensure call). Either way it is poison.
- Every caller of a covered function is either covered or holds a run with an ensure
  (§2.6(a)).

So the 02 rule is:
- a marker in a covered function is leaf;
- a marker in a non-covered function is poison;
- a call from a non-covered function to a covered one is poison (it implies an ensure).

The remaining subtlety: `eco-cap-covered` must be emitted only when hoisting is `On`.
With `=c` or `=0`, hoisting produces no decisions, and treating covered markers as leaf
there would be unsound. The assert would still catch it.

**O4. EcoSplit's attribute copy is the only new place a fact can be lost.**
- **Rule:** copy a whitelist only: `gc-leaf-function`, `eco-cap-covered`,
  `eco-cap-budget`, `eco-cap-top`. Every generated decl gets exactly one of budget/top
  (F11). The master plan §4.2 says "passthrough" is copied wholesale. That conflicts with
  this rule, and the whitelist governs.
- **Never copy** memory, willreturn or speculatable onto a declaration whose signature
  carries `!eco.value` (REP_LLVM_002).
- **Losing gc-leaf is safe but costly:** extra statepoints, so the byte-identity check
  catches it.
- **Losing coverage is unsafe** without O1's mitigation.
- **Adding gc-leaf where the definition has none is unsafe and invisible locally** (F5).

**O5. Whether `__eco_value_eq` arm 3 is leaf is a module-global fact today.**
- `materializeAllRuntimeDecls` always declares `Elm_Kernel_Utils_equal` with gc-leaf
  (`P/EcoToLLVMRuntime.cpp:1340`).
- The unused-declaration strip (`P/EcoToLLVM.cpp:~600-640`) then deletes it if nothing
  else calls it.
- In that case the expansion creates a fresh, non-leaf declaration, unless
  `ECO_VALUE_EQ_GCLEAF=1` (`EB:2384-2393`).
- Per partition, this becomes "does this partition reference `Utils_equal`".
- The documentation disagrees too. The gc-free plan §1.3 (`plans/gc-free-function-propagation.md:174`,
  written before kernel-opt-08) lists `Elm_Kernel_Utils_equal` as poison. CGEN_072(a) does
  **not** name it: it says "every kernel extern EXCEPT clause (f)", and `Utils.equal` is an A1
  row in `KernelFacts.elm:434` (`gcAlloc = GcNone`), so (f) permits the stamp. The real conflict
  is with (f)'s "exactly ONE channel / no C++ name list": `getOrCreateUtilsEqual` hard-codes
  `gcLeaf=true`, so `ECO_KERNEL_GCLEAF=0` does **not** unstamp it. F4's bisection switch is
  incomplete for this symbol.
- **Fix:** one predicate in the table. The expansion stamps the declaration per that
  predicate, so the outcome no longer depends on the strip.
- The `EB:2364-2368` comment ("nothing emits `eco.value.eq` today") is **stale**:
  - the front end emits it under `ECO_VALUE_EQ` (`Config.elm:745-764`, `Expr.elm:1426`);
  - string-case lowering emits it under `ECO_VALUE_EQ_STRCASE`
    (`P/EcoControlFlowToSCF.cpp:816/863`, `P/EcoToLLVMControlFlow.cpp:425-431`).

  Both are off by default. With STRCASE on, the string-case sites stop calling
  `Utils_equal` directly, which is exactly what lets the strip remove the stamped declaration.
  So O5 is live in a reachable configuration. Put both switches in the step-4 matrix. M2f
  still sizes the default case.

**O6. The `$cap` prepass and DCE make the two sides' populations differ.**
- AlwaysInliner deletes inlined internal `$cap`s.
- IPSCCP's GlobalDCE deletes more.
- MLIR stamps functions that LLVM never sees.
- Validate mode must compare on the surviving intersection.
- **Soundness is preserved:** a stamped caller only calls stamped or leaf callees, so
  inlining never puts a GC-capable call into a stamped body.
- **Equality is not preserved (review R4).** `InlineFunction` clones through
  `CloneAndPruneFunctionInto`, which folds branches on constant actual arguments and does
  not clone the dead arms. It also substitutes actuals, so a callee's `call %arg` becomes a
  direct call when the caller passes `@f`. Either effect can delete a caller's only poison
  site. Then S_llvm ∋ f ∉ S_mlir. That direction is safe (MLIR stamps less), but it breaks
  "S_mlir ∩ survivors == S_llvm" and the step-5 byte-identity gate. Measure it (M6). If it is
  non-zero, choose one of:
  - accept ⊆ and shift the byte-identity baseline;
  - keep the LLVM fixpoint as an **additive**, partition-local stamper after the prepass. It
    is sound because it stamps only definitions it proves locally; cross-partition decls just
    don't learn the extra stamps.

**O7. An MLIR "indirect" call can be an LLVM "direct" call.**
- `llvm.call %p` where `%p = llvm.mlir.addressof @f` translates to `call @f`.
- The MLIR pass must apply the same rule as 01, or its result is a strict subset of the
  LLVM one.
- **Mismatched type (01's E6).** `callsGCLeafFunction` (a) reads gc-leaf through
  `getCalledOperand()` with no type check. So in LLVM, an `addressof @d` + `llvm.call` with a
  *mismatched* type to a gc-leaf **declaration** is leaf, not poison. To be exact, MLIR must
  emulate this for declarations. For definitions it need not: today they are unstamped at
  fixpoint time, so LLVM poisons that call too.
- The reverse case (MLIR direct, LLVM indirect after a type mismatch) cannot arise: the
  `llvm.call` verifier pins the callee type. Even if it could, RS4GC would statepoint the
  call and the assert would fire.

**O8. 02 must be the last MLIR pass that changes bodies.**
- An MLIR pass placed later (a future 04-style rewrite, or a DCE inside EcoSplit) could
  invalidate stamps silently.
- The assert covers the GC-call case. It does not cover F5.
- Pin the placement in the pipeline with a comment and in the invariant text.

**O9. The barriers-off fallback changes output.**
- With `ECO_SLOT_CAST_BARRIERS=0` or `ECO_CAP_INLINE_GCFREE_ONLY=1`, `bodyIsGCCallFree`
  now sees propagated stamps, so more `$cap` bodies qualify.
- This is sound, because a stamped callee cannot GC transitively.
- It is a non-default output change. Exclude these configurations from the byte-identity
  gate.

**O10. Scratch helpers.**
- Putting `eco.gc_leaf` on the EcoListTemplate stubs is the single-channel route
  (CGEN_072(f)). It also makes EcoMarkGCLeafCalls stamp `eco.callee_gc_leaf` on those
  calls, which changes EcoGCPrepare's rooting.
- CGEN_077(b) says rooting changes emit identical LLVM IR, but that is a claim to
  re-verify, not assume.
- The `eco.gc_leaf` route also puts the scratch stamps under `ECO_KERNEL_GCLEAF=0` /
  `ECO_KERNEL_GCLEAF_EMIT`, and CGEN_072(f) scopes that channel to KernelFacts rows. Today the
  `EB:3670` stamp is unconditional. So the route changes the bisection switch's meaning: under
  `ECO_KERNEL_GCLEAF=0`, S shrinks versus today. Either amend (f), or use the fallback.
- Fallback: a passthrough stamp written by EcoToLLVM.
- Decide by the byte-identity gate.

## 4. GC-safety argument

**Claim.** After the split, no call that can reach a GC executes while the stack is not
parseable. The trusted base is the same as today: runtime and kernel declarations do not
lie about gc-leaf, per KernelFacts / CGEN_072(f) and runtime audits.

**The global property.**
- **(G):** for every call site c in a function with a GC strategy, if RS4GC did not
  statepoint c, the callee cannot GC.
- **Proof obligations per partition:**
  - **(L1)** the post-RS4GC assert: no stamped definition contains a statepoint;
  - **(L2)** every call RS4GC skips targets one of: a trusted declaration, an intrinsic or
    TLI libcall, a stamped definition in this partition, or a declaration stamped because
    EcoSplit copied it from another partition's definition.
- **The cross-partition link:**
  - **(X)** every stamped cross-partition declaration has a stamped owner definition,
    which satisfies (L1) in its own partition.
- **Induction:** follow non-statepointed calls to a depth. Each step lands in a body whose
  calls are all non-statepointed (by L1), and the recursion bottoms out in trusted leaves.
  Cycles are fine: a cycle in which no member can GC cannot GC.

**Every way a function could be stamped while containing a call that can GC, and how it is
detected:**

| # | Failure | Example | Detection |
|---|---|---|---|
| F1 | Table says leaf, expansion emits a non-leaf call | `__eco_list_tail_inline` misclassified | RS4GC statepoints it inside a stamped function → **L1 assert**. Plus the per-expansion table assert, which names the marker |
| F2 | An LLVM-level transform adds a non-leaf call the plan did not predict | ensure in a function 02 stamped; sat indirect call; `eco_alloc_inline_slow` in a non-covered function | **L1 assert** |
| F3 | Direct/indirect mismatch | the O7 reverse case | **L1 assert** |
| F4 | Lying trusted declaration | a kernel row wrongly gcLeafEligible | **not structural** (as today); `ECO_KERNEL_GCLEAF=0` bisection, heap-validate legs |
| F5 | Cross-partition declaration stamped, owner definition not stamped (or changed) | an EcoSplit copy bug; a pass after 02 | **nothing per partition.** New **(X) join check**: every worker reports (owned stamped definitions, stamped external declarations); the driver checks declarations ⊆ definitions before linking. Cost: one set join over the cross-partition symbols |
| F6 | Stamped function without a GC strategy (`__eco_init_globals`) that calls a GC-capable callee | none today | the assert is vacuous here (RS4GC skips the body) → **local check** (callsGCLeafFunction over stamped definitions, independent of `hasGC`). This is the one class where the local check adds safety |
| F7 | Interposable or weak body | not emitted | poison on both sides; the local check asserts no stamped interposable definition |
| F8 | Post-RS4GC inlining of a statepointed `available_externally` `$cap` copy (01) into a caller | a copy that survives the prepass | **not an 02 stamping failure,** but in the same family (E1.4). 01 must turn non-inlined copies back into declarations **before** RS4GC. The local check asserts that no `available_externally` definition remains |
| F9 | Headroom (not GC) corruption through a stamped covered callee | O1 | O1's budget-0 rule + a hard error for "generated callee with gc-leaf, not covered, budget ≠ 0" |
| F10 | Env-switch disagreement between the MLIR pass and the backend | `ECO_VALUE_EQ_GCLEAF`, `ECO_VALUE_EQ_STRCASE`, `ECO_KERNEL_GCLEAF`, `ECO_ALLOC_HOIST`, `ECO_SAT_FAST`, `ECO_GCFREE_LEAF`; also 01's gating "hoisting On requires gcfree Stamp" (`EB:3687-3698`), which the MLIR 01 pass must replicate | one helper per switch in the shared header, read by both. Same process, cached statics (no path re-reads a serialized llvm-dialect module; `-emit=mlir-llvm` is dump-only) |
| F11 | Stamped cross-partition decl lost its `eco-cap-*` copy but kept gc-leaf | an EcoSplit whitelist bug | **headroom corruption, silent**: every classifier would read it as a runtime decl → transparent. The O1 trusted-set assert (a gc-leaf decl without `eco-cap-*` must be a runtime/kernel name) makes it a hard error |

**Not failure modes:**
- **musttail:** not emitted, see §0 item 6.
- **IPSCCP or other optimizer-materialized libcalls:** classified leaf by RS4GC's own TLI;
  sound by construction (gc-free plan §2.5).

The local check (pre-RS4GC, per partition) is a superset of the assert. It is worth
keeping:
- it covers F6;
- it covers the F7 and F8 structural asserts;
- it gives readable diagnostics before RS4GC rewrites the IR (cheap: one walk over the
  stamped definitions).

## 5. Design (revised)

### 5.1 Shared marker table (new header, e.g. `runtime/src/codegen/EcoMarkerFacts.h`)

**One constexpr row per name.** Columns:
- name;
- declared-leaf bit (what the MLIR declaration carries; it is consulted by nothing once
  expanded);
- **hoisting view** (01's Phase A, step-8 position): transparent / ⊤ / alloc-marker /
  Predicate. `__eco_list_tail_inline` is ⊤ even though it is declared leaf, and sat is
  transparent;
- **final view** ("may GC once expanded", 02): `Never` / `Always` / `UnlessCovered` /
  `Predicate`;
- the expansion function;
- the callees the expansion may emit.

The declared bit and the hoisting view differ (list-tail), so they cannot share a column.
This reconciles with 01 §2.2's "two columns". Note that 01 §2.2's table lists the cursor
markers as "MLIR decl, gc-leaf". The code says otherwise (O2), so fix 01 when it is next edited.

**Rows:**

| Marker | Class |
|---|---|
| `__eco_resolve_fwd`, `__eco_get_tag_inline`, `__eco_list_head_inline`, `__eco_string_len_inline`, the 6 cursor markers, `__eco_slot_to_hptr`, `__eco_hptr_to_slot` | Never |
| `__eco_list_tail_inline` | Always |
| `__eco_sat_begin`, `__eco_sat_end` | Always: indirect fast call; already poisoned by the slow sequence |
| `__eco_alloc_inline` | UnlessCovered |
| `__eco_value_eq` | Predicate (O5) |

**Also in the header:**
- `isHeadroomBreaker` (`EB:2888`), so 01's MLIR Phase A and plan-given D share it;
- the env helpers (`gcFreeLeafMode`, `kernelGcLeafEnabled`, `valueEqGcLeafEnabled`,
  `capHoistMode`).

**Consumers:**
- runtime declaration creation (leaf bit);
- `EcoListCursor::ensureFn`;
- every LLVM expansion: a debug and validate assert that emitted callees ⊆ the row's list,
  and that their leafness matches the class;
- `EcoCapHoistPlan` (01);
- `EcoGcFreePropagation` (02).

**Owner:** the codegen layer, next to `EcoToLLVMInternal.h`, not RuntimeSymbols. This
answers the old open question.

### 5.2 `EcoGcFreePropagation` (MLIR, llvm dialect)

**Placement:** after EcoTailConversions → 03 → 01. It is the last body-reading pass
(O8).

**Per-function facts, collected in parallel (`parallelFor` over `llvm.func`):**
- **Poison** if any of:
  - linkage is interposable;
  - an `llvm.invoke` or landing pad is present;
  - an `llvm.inline_asm`, or any other op that implements `CallOpInterface` and is not
    `llvm.call` or a recognised intrinsic op. Enumerate by interface, not by
    `isa<LLVM::CallOp>` (none of these is emitted today; the rule is defensive);
  - an indirect call that does not resolve through `addressof` with a matching type, unless
    it targets a gc-leaf **declaration** (O7, E6);
  - a call to a declaration that is neither in the table nor stamped leaf, and is not a
    *recognised* intrinsic (`llvm::Intrinsic::lookupIntrinsicID(name) != not_intrinsic`,
    excluding statepoint, deoptimize and element-unordered-atomic memcpy/memmove, per §1.3(c));
  - a table marker of class Always;
  - an UnlessCovered marker in a function without `eco-cap-covered`;
  - a call to an `eco-cap-covered` callee from a function without `eco-cap-covered`.
- **Edges:** direct calls to defined, non-interposable functions.

**Then:**
- a serial worklist, identical to `EB:2791-2797`;
- stamp with `attachGcLeafPassthrough`;
- write the `ECO_GCFREE_LEAF_DUMP` file and `[gcfree]` lines in the same format;
- census and off modes as today.

**Cheap cross-check against 01 (stamp mode only):** every `eco-cap-budget="0"` function
must be stamped. This is 01's "budget 0 ⇒ stamped" promise, now checkable in one place. It
holds only if the hoisting view and the final view agree on every non-⊤ row. The one known
gap is a sat bracket without a non-leaf generic call (01's Q3). That would fire here
loudly, which is the desired outcome.

### 5.3 Split and partitions

- EcoSplit copies the whitelisted attributes (O4).
- Per partition: the expansions, with the table asserts.
- Plan-given D/D2 uses the budget-0 rule (O1).
- Then the local check (F6-F8), RS4GC with the L1 assert, and FP.
- Each worker returns its two name sets for the (X) join (F5).

## 6. Measurements before building

Measure on the self-compile, default configuration, using the existing dumps
(`--dump-pre-rs4gc-ir`, `ECO_GCFREE_LEAF_DUMP`, the `--emit=mlir` llvm-dialect output). No
new code paths.

| # | Measure | Why |
|---|---|---|
| M1 | Today's stamped set S_llvm, with hoisting On and with `=0` | the oracle; confirms the 2,372 / 8,473 split |
| M2a | Functions that contain a cursor marker and are in S_llvm | sizes O2 |
| M2b | `addressof`-fed indirect calls in the llvm dialect that become direct in LLVM, and how many sit in S_llvm functions | O7 |
| M2c | Call sites that are leaf **only** through the TLI arm (declaration without gc-leaf, not an intrinsic) | decides whether MLIR may treat them as poison or needs a TLI name list |
| M2d | Calls to scratch helpers inside S_llvm functions | O10 |
| M2e | `__eco_list_tail_inline` and sat-marker counts in functions that are otherwise free | confirms the Always rows cost nothing |
| M2f | Number of `__eco_value_eq` markers, and whether `Utils_equal` survives the strip | O5 |
| M3 | S_llvm ∩ (budget ⊤) and S_llvm ∩ covered, from the 01 census | confirms O3's "stamped ⇒ covered or budget 0" |
| M4 | Under today's 24 LPT partitions: stamped functions with a caller in another partition, and stamps that depend only on a cross-partition callee | size of the (X) join; the cost of a conservative per-partition fallback |
| M5 | Run-scan breakers today that are calls to S_llvm budget-0 definitions | how many runs would change if O1's rule were missing (the size of the byte-identity hazard) |
| M6 | S_llvm with the `$cap` prepass on versus `ECO_CAP_INLINE_MAX_INSTS=0`: functions that become free *only* after inlining (pruned dead arms, or indirect → direct) | O6 equality; decides ⊆ acceptance vs an additive LLVM stamper |
| M7 | mismatched-type `addressof` calls to gc-leaf declarations | O7/E6 emulation needed or not |

## 7. Steps and acceptance criteria

1. **Shared table and expansion asserts** (ships now, independent of the split).
   - Header, rows, and env helpers moved into it.
   - Expansions assert against the table.
   - Cursor declarations get gc-leaf from the table.
   - **Accept:** ELF byte-identical to HEAD. The cursor stamp is inert on the LLVM path
     because the markers are expanded before step 13. `check` is green.
2. **Move the backend-only stamps to MLIR.** That means the scratch helpers (O10 route)
   and the `Utils_equal` predicate (O5).
   - **Accept:** ELF byte-identical; S_llvm unchanged (M1 diff empty).
3. **Local check plus (X) machinery** on today's pipeline, behind validate. Today's split
   cannot fail (X) by construction, so this proves the plumbing.
   - **Accept:** zero findings on the self-compile and E2E.
4. **`EcoGcFreePropagation` in census mode,** after 01's MLIR pass. Validate mode, single
   module:
   - save S_mlir;
   - strip gc-leaf from every LLVM definition before step 13, so the LLVM fixpoint cannot
     simply agree with MLIR's stamps through `callsGCLeafFunction`;
   - run the LLVM fixpoint;
   - require **S_mlir ∩ survivors ⊆ S_llvm**, and equality except for the M6 class
     (inlining-only frees), with every diff reported together with its poison reason.
     **S_mlir ⊄ S_llvm is a soundness bug** and must stop the build in validate mode.

   Run the env matrix:
   - `ECO_ALLOC_HOIST` = On / c / 0;
   - `ECO_GCFREE_LEAF` = c / 0 (MLIR must stamp nothing; 01 must emit no covered);
   - `ECO_KERNEL_GCLEAF=0`;
   - `ECO_VALUE_EQ_GCLEAF=1`, `ECO_VALUE_EQ_STRCASE=1`, `ECO_VALUE_EQ=1` (front end),
     `ECO_VALUE_EQ_INLINE=0`;
   - `ECO_SAT_FAST=0`;
   - `ECO_CAP_INLINE_MAX_INSTS=0` (isolates M6);
   - `ECO_SLOT_CAST_BARRIERS=0` (O9: soundness leg only, not identity);
   - `list.chunks` on and off;
   - the JIT kind (`allowTls=false`; `-emit=jit` fixtures);
   - -O0.

   **Accept:** zero unexplained diffs on the self-compile and the E2E corpus.
5. **Stamp mode,** with the LLVM fixpoint turned into a census (`ECO_GCFREE_MLIR=0` keeps
   the old path for one series). Requires 01's plan-given mode with O1's rule.
   - **Accept:** ELF byte-identical to the LLVM path, excluding O9's configurations and
     any M6 residue; bootstrap fixed point; heap-validate leg green (stress tests at
     GC-pressure heap config, never the default, per MEMORY).
   - **Fixture churn is expected.** Definitions now carry `passthrough =
     ["gc-leaf-function"]` in `-emit=mlir-llvm` output, and the attribute groups shift in
     `-emit=llvm`. Re-baseline `test/codegen` (for example `slot_cast_barriers_emit.mlir`,
     `string_list_append.mlir`, `value_sret_result_llvm.mlir`,
     `list_map_template_statepoint_free.mlir`) and review every diff by hand. A diff is
     only acceptable if it adds stamps and does not change CHECK-NOT statepoint lines.
   - **Gate:** the LLVM `applyCapacityHoisting` hard-errors on stamped definitions (O1). A
     fixture covers it: a covered callee pre-stamped gc-leaf whose caller's budget must not
     drop (01 S4 fixture (b)), plus a gc-leaf decl stripped of `eco-cap-*` (F11).
6. **With the split (master §4):** the (X) join and the local check are always on in
   stamp mode.
   - **Accept:** zero (X) findings; L1 green in every worker; FP stamp counts equal to the
     non-split run.
7. **Update the invariants.**
   - CGEN_072: the producer is `EcoGcFreePropagation`; placement; table; (X); scratch and
     `Utils_equal` clauses; fix the poison-list contradiction.
   - CGEN_074: plan-given transparency = budget 0, never gc-leaf.
   - CGEN_077: 02 never writes `eco.callee_gc_leaf`.
   - REP_LLVM_002: the EcoSplit whitelist.
   - CGEN_073: unchanged.

## 8. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| O1 headroom hole after the inversion (Phase A, D, D2, §2.6(b), 01 §4.3) | heap corruption, silent | eco-cap attributes decide generated callees before `callsGCLeafFunction` (01 R1/R3); the trusted-set assert for gc-leaf decls without `eco-cap-*` (F11); the LLVM full hoisting refuses stamped definitions. Step 5 cannot ship without all three |
| Inlining-only frees (O6, M6) | gate failure, not safety | ⊆ acceptance, or an additive local LLVM stamper |
| F5 declaration/definition mismatch across partitions | heap corruption, silent per partition | (X) join, always on; whitelist copy from one MLIR source |
| Table drift (a new marker added without a row) | build error | an expansion with no row is `report_fatal_error`; every `getOrInsertFunction` in `EB` pre-RS4GC goes through the table |
| Validate mode agrees vacuously (LLVM reads MLIR stamps) | false green | strip stamps on definitions before the LLVM census (step 4) |
| Byte-identity broken by extra `eco-cap-*` string attributes in IR | gate noise | compare `.text`/stackmaps if the ELF differs only in IR-only metadata; string fn attributes do not reach codegen |
| Scratch-helper route changes GCPrepare output (O10) | gate failure | fall back to an EcoToLLVM passthrough stamp |
| Disk use from validate builds producing cores | operations | `ulimit -c 0` (MEMORY: test binaries / core dumps) |

## 9. Open questions

1. Is `Elm_Kernel_Utils_equal` leaf or not? The code (`P/EcoToLLVMRuntime.cpp:927`) and
   the KernelFacts A1 row (`KernelFacts.elm:434`) say yes. Only the stale gc-free plan says
   poison (CGEN_072(a) defers to (f)). `ECO_VALUE_EQ_GCLEAF` defaults to off and matters only
   for the fresh declaration created after the strip. **Proposed:** leaf, routed through the
   (f) channel, so that `ECO_KERNEL_GCLEAF=0` unstamps it. That still needs an owner decision
   before step 2.
2. Should O1's rule go further and make plan-given D read `eco-cap-budget` for *all*
   generated callees, never `callsGCLeafFunction`? That is cleaner, but D's scan code then
   diverges from today's.
3. Is (X) cheaper as a worker-side report joined by the driver, or as an EcoSplit-side
   assertion? EcoSplit-side runs before the LLVM passes, so it cannot see O8-class drift.
   The worker side can.
4. Should the TLI arm (M2c) be mirrored by a name list, or are such calls absent? If they
   are absent, MLIR's poison rule is exact.
5. Do the cursor declarations get gc-leaf in MLIR (step 1)? Would that change anything
   else that reads them (EcoGCLivenessAudit only sees `eco.call`)? Confirm with a grep
   when implementing.
6. Keep the LLVM `propagateGcFreeLeafAttrs` permanently as the validate twin, or delete
   it after one series? Recommendation: keep it as a census, since it is the only
   independent oracle.

# Part II: implementation specification

Part I is the feasibility analysis. Part II is the build specification. Plan 00 (SP3) measured
an **exact** MLIR/LLVM match on the self-compile, and **M6 = 0**: no function becomes GC-free
only through `$cap` inlining. So the identity route (O6 option 1) needs no LLVM additive
stamper. Plan 01 is implemented, and its plan-given mode already classifies eco-cap facts
before gc-leaf (R1) and treats a non-covered generated callee as a breaker (R3). That
closes O1 for Phase A, D, D2, §2.6(b) and the §4.3 verification.

## Q0. Decisions taken (answers to §9)

| Q | Decision | Why |
|---|---|---|
| 1 `Utils_equal` leafness | **Unchanged: leaf,** routed through the (f) switch. `getOrCreateUtilsEqual` passes `gcLeaf = kernelGcLeafEnabled()`, so `ECO_KERNEL_GCLEAF=0` now unstamps it. Value-eq arm-3 leafness stays the module predicate `veq = ECO_VALUE_EQ_GCLEAF=1 ∨ (the module holds a gc-leaf Utils_equal decl)`, computed once in MLIR and carried in the plan flag. `expandValueEqFastPath` stamps the decl it creates when `veq` holds, so a partition that lacks the decl reaches the same answer (O5) | byte-identical by default; makes F4's bisection switch complete |
| 2 D reads facts for all generated callees | Already true in plan-given mode (01 R1/R3). Nothing to add | |
| 3 (X) where | **Worker side:** each partition reports after RS4GC; the driver joins after `join()` | it also sees per-partition drift |
| 4 TLI arm | Libm name list only (`markers::isLibmLeaf`). M2c = 0 | exact on the self-compile |
| 5 Cursor declarations | **Not re-declared.** The final view says Leaf; the MLIR declarations stay as they are | the stamp would be inert (expanded before step 13) and would touch EcoGCLivenessAudit's inputs for nothing |
| 6 LLVM fixpoint | **Kept as the validate twin** (`ECO_GCFREE_VALIDATE=1`) and as the whole path when MLIR does not stamp (`ECO_GCFREE_MLIR=0`, census, or no plan flag) | the only independent oracle |
| O10 scratch helpers | **Stay stamped by name in `runEcoBackend`.** The table classifies them Leaf; the declaration assert (P3) pins both views | name stamps are partition-local and idempotent, so the split needs no move; this avoids O10's GCPrepare and `ECO_KERNEL_GCLEAF` side effects |

## Q1. Scope

| Item | In scope | Notes |
|---|---|---|
| J1 table final view + declaration assert | yes | §5.1, F1 |
| J2 `EcoGcFreePropagation` MLIR pass (stamp mode) | yes | §5.2 |
| J3 backend consumes the MLIR stamps; LLVM fixpoint becomes validate twin | yes | step 5 |
| J4 01 compute-mode Phase A stamp-agnostic | yes | needed by 01's validate twin and `ECO_ALLOC_HOIST=c` once definitions are stamped |
| J5 local check (pre-RS4GC, every RS4GC flavour) | yes, always on in stamp mode | F6–F8 |
| J6 (X) cross-partition join | yes, always on in stamp mode, on today's `cgu` partitions | F5; today it cannot fail by construction, so it proves the plumbing |
| J7 `Utils_equal` routing (Q0.1) | yes | O5 |
| J8 fixtures, gates, invariants | yes | |
| EcoSplit whitelist copy (O4, step 6) | **deferred** to the master plan's split milestone | no MLIR split exists |

## Q2. Files

| File | Change |
|---|---|
| `P/EcoMarkerFacts.h` | add `enum class Final`, `finalView()`, `expansionCalleeLeaf()`, `isMarkerName()` |
| `P/EcoCapHoistCore.h/.cpp` | add `valueEqGcLeafEnv()`, `gcFreeMlirEnabled()`, `gcFreeValidateEnabled()`, the `kGcFreePlanFlag` vocabulary and `GcFreeStamp` encode/parse |
| `P/EcoGcFreePropagation.cpp` (new) | the MLIR pass |
| `Passes.h`, `EcoPipeline.cpp`, `CMakeLists.txt` | declare, add after `EcoCapHoistPlan` (last pass, O8), build |
| `EcoBackend.cpp` | J3, J4, J5, J6, J7 (expansion side), declaration assert |
| `P/EcoToLLVMRuntime.cpp` | J7: `getOrCreateUtilsEqual` gcLeaf = `detail::kernelGcLeafEnabled()` |
| `test/codegen/gcfree_plan_*.mlir` (new) | fixtures (Q8) |
| `design_docs/invariants.csv` | CGEN_072, CGEN_074, CGEN_077 |

## Q3. J1: the marker table's final view

```cpp
enum class Final { FromDecl, Leaf, Poison, UnlessCovered, ValueEq };
Final finalView(StringRef callee);
```

| Row | Final |
|---|---|
| `__eco_alloc_inline` | UnlessCovered |
| `__eco_list_tail_inline`, `__eco_sat_begin`, `__eco_sat_end` | Poison |
| `__eco_value_eq` | ValueEq (`veq`) |
| `__eco_resolve_fwd`, `__eco_get_tag_inline`, `__eco_list_head_inline`, `__eco_string_len_inline`, `__eco_slot_to_hptr`, `__eco_hptr_to_slot`, the cursor markers, the scratch helpers | Leaf |
| anything else | FromDecl (gc-leaf passthrough, libm, recognised intrinsic) |

`isMarkerName(c)`: `c` starts with `__eco_` and is a function. An `__eco_` callee with no
row is a hard error in the MLIR pass ("marker without a table row"), so a new marker
cannot slip through as FromDecl.

**Expansion-callee column,** `int expansionCalleeLeaf(StringRef, bool veq)` (-1 = not a
row, 0 = must not be gc-leaf, 1 = must be gc-leaf):

| Callee emitted by an expansion | Expected |
|---|---|
| `eco_list_tail_hybrid`, `eco_alloc_inline_slow`, `eco_ensure_nursery_slow` | 0 |
| `eco_list_head_hybrid`, `__eco_resolve_fwd`, `eco_follow_forward`, `__eco_slot_to_hptr`, `eco_bump_state`, scratch helpers | 1 |
| `Elm_Kernel_Utils_equal` | `veq` |

**Declaration assert** (`checkMarkerDecls(Module&, optional<bool> veq)` in `EB`): for every
*declaration* in the module whose name has a row, `hasFnAttribute("gc-leaf-function")`
must equal the expectation. `callsGCLeafFunction` on a direct call reduces to exactly that
(no call-site attributes are emitted), so checking declarations is equivalent to 01's
per-call walk and costs O(#decls). Called at two points:
1. in plan-given hoisting, replacing 01's P6.6 per-call walk;
2. at step 13 (the gc-free choke point), in stamp mode, so all expansion callees exist.
The `Utils_equal` row is checked only when `veq` is known (a plan flag is present).

## Q4. J2: `EcoGcFreePropagation` (`P/EcoGcFreePropagation.cpp`)

Factory `eco::createEcoGcFreePropagationPass()`. Argument `eco-gcfree-propagation`.

1. **Gate.** Return unless `gcFreeLeafMode() == Stamp` and `gcFreeMlirEnabled()`
   (`ECO_GCFREE_MLIR`, default on; `0` keeps the LLVM producer).
2. **Pre-planned input.** If the module flag `eco-gcfree-plan` exists, return (re-lowered
   dumps and fixtures). Otherwise, a **definition** with gc-leaf whose name is not
   `isTrustedLeafDecl` is an error ("gc-leaf definition without a gc-free plan").
3. **Coverage source.** `capPlan` = the `eco-cap-plan` flag exists. If not, no function may
   carry `eco-cap-covered` (error). `cov = capPlan`.
4. **`veq`** = `valueEqGcLeafEnv()` ∨ (`Elm_Kernel_Utils_equal` is in the module and
   gc-leaf). If `capPlan`, it must equal the cap stamp's `veq` (error otherwise).
5. **Index** top-level symbols as in 01 (name → node, `defined`, `interposable`, `covered`
   = passthrough `eco-cap-covered`).
6. **Facts, `parallelForEach` over definitions.** Poison when any of:
   - interposable linkage;
   - an op that is `LLVM::InvokeOp`, `LLVM::LandingpadOp` or `LLVM::InlineAsmOp`, or any
     other op implementing `CallOpInterface` that is not `LLVM::CallOp`;
   - an `LLVM::CallOp`, resolved as 01 does (direct; `addressof` with a matching type =
     direct; `addressof` with a mismatched type = via-operand; otherwise indirect):
     - direct to a defined, non-interposable function `g`: an **edge**. Additionally
       poison if `g` is covered and `f` is not (the caller holds an ensure, O3);
     - direct to a defined interposable function: poison;
     - direct to a declaration: `finalView(name)`:
       - Leaf → nothing;
       - Poison → poison;
       - UnlessCovered → poison unless `f` is covered;
       - ValueEq → poison unless `veq`;
       - FromDecl → leaf iff the declaration has gc-leaf, or `isLibmLeaf(name)`, or it is
         a recognised intrinsic (`llvm::Intrinsic::lookupIntrinsicID(name)` is not
         `not_intrinsic` and is not `experimental_gc_statepoint`,
         `experimental_deoptimize`, or the element-unordered-atomic memcpy/memmove/memset);
         otherwise poison. In addition, a covered declaration called from a non-covered
         `f` is poison (as for definitions);
       - an `__eco_` name with no row → pass failure;
     - via-operand: leaf iff the target is a gc-leaf **declaration** (E6); otherwise poison;
     - indirect: poison.
7. **Fixpoint.** Reverse edges, an optimistic worklist from the poison seeds (identical to
   `EB` `propagateGcFreeLeafAttrs`).
8. **Stamp** `"gc-leaf-function"` into the passthrough of every non-poisoned definition
   (append, keeping existing entries).
9. **Flag** `eco-gcfree-plan` = `v1;veq=<0|1>;cov=<0|1>` (`ModFlagBehavior::Warning`).
10. **Stats.** `ECO_GCFREE_PLAN_STATS=1` prints
    `[gcfree-plan] defined=N free=M cov=C veq=V time=Ts`.

**Placement:** directly after `EcoCapHoistPlan` (it reads `eco-cap-covered`), and last in
`buildEcoToLLVMPipeline` (O8). Add a comment that no body-changing pass may follow it.

## Q5. J3 + J7: the backend

In `runEcoBackend`, before the first expansion:
- read `gcPlan = readGcFreePlan(m)` (optional `{veq, cov}`); a malformed flag is an error;
- `gcPlan` with `gcFreeLeafMode() != Stamp` → error "gc-free plan stamp without stamp mode";
- `gcPlan->cov` without an `eco-cap-plan` flag → error (unchecked markers would have been
  read as leaf with no hoisting to make them so);
- both flags present with different `veq` → error.

`expandValueEqFastPath(m, planVeq)`: stamp the `Utils_equal` declaration when
`valueEqGcLeafEnabled() || planVeq` (J7, O5). `planVeq` comes from `gcPlan` or the cap stamp.

At step 13, when `gcFreeLeafMode() != Off`:
- **`gcPlan` present** (MLIR stamped):
  1. `checkMarkerDecls(m, gcPlan->veq)`;
  2. if `gcFreeValidateEnabled()`: run `propagateGcFreeLeafAttrs` in **twin mode**: no
     stamping, and a call to a defined, non-interposable callee is an edge *before*
     `callsGCLeafFunction` is consulted, so MLIR's stamps cannot make the twin agree
     vacuously. With S_mlir = stamped survivors and S_llvm = the twin's free set:
     - S_mlir \ S_llvm ≠ ∅ → hard error, listing up to 20 names ("MLIR stamped what LLVM
       proves can GC");
     - S_llvm \ S_mlir is reported, not fatal: it is the safe direction (M6 class or
       post-plan definitions such as the JIT's `_mlir_*` wrappers);
     - prints `[gcfree-validate] mlir=N llvm=M mlir_only=0 llvm_only=K`;
  3. `ECO_GCFREE_LEAF_DUMP` writes the stamped survivors; the `[gcfree]` line prints when
     `ECO_GCFREE_LEAF` is named (`source=mlir`); `ECO_CAP_GCLEAF_REPORT` unchanged;
  4. strip the `eco-gcfree-plan` flag (it must not reach the object).
- **no `gcPlan`:** today's `propagateGcFreeLeafAttrs` unchanged, followed by
  `checkMarkerDecls(m, nullopt)`.

## Q6. J4: compute-mode Phase A becomes stamp-agnostic

In `applyCapacityHoisting`'s `runPhaseA` with `r1 == false`: test "callee is a defined,
non-interposable function whose name is not `isTrustedLeafDecl`" → edge, **before**
`callsGCLeafFunction`. With no stamped definitions this is today's order exactly (a
defined callee is leaf only if stamped). With stamped definitions it makes 01's validate
twin compare like with like.

The compute-mode R2 mirror then stays only for `mode == On` (the transform: Phase D's
transparency rule still reads gc-leaf). In census mode (`ECO_ALLOC_HOIST=c`) stamped
definitions are allowed: with no cap plan, MLIR's covered set is empty, so every stamped
function is marker-free with stamped callees (budget 0 in both readings).

## Q7. J5 + J6: local check and (X) join

**Local check,** `checkStampedBodies(Module&)` in `runRS4GCAndMaybeFramePointers`, before
RS4GC, stamp mode only. For every defined function with gc-leaf:
- interposable or `available_externally` linkage → error (F7, F8);
- every `CallBase` must satisfy `callsGCLeafFunction` (a stamped callee qualifies through
  its attribute) → error "stamped function '%s' calls '%s', which may GC" otherwise. This
  is independent of `hasGC()`, so it covers F6 (`__eco_init_globals`).

It runs in every RS4GC flavour, so each worker checks its own partition.

**(X) join** in `emitObjectFilesSplitLazy` and `emitObjectFilesSplit`. Each worker, after
its RS4GC, records:
- `stampedDefs`: names of its gc-leaf definitions;
- `allDefs`: names of all its definitions;
- `leafDecls`: names of its gc-leaf declarations.

After `join()`, for every `d` in ∪ `leafDecls` with `d` ∈ ∪ `allDefs`: require
`d` ∈ ∪ `stampedDefs`. Otherwise error "cross-partition gc-leaf declaration '%s' has an
unstamped owner (CGEN_072 X)". Stamp mode only. `[gcfree-x] partitions=P decls=D checked=C`
prints under `ECO_GCFREE_PLAN_STATS`.

## Q8. J8: fixtures and gates

**Fixtures** (`test/codegen`, llvm-dialect input, `-emit=mlir-llvm` unless noted):

| Fixture | Content | Expect |
|---|---|---|
| `gcfree_plan_basic.mlir` | `@leaf` (no calls); `@mid` calls `@leaf` and a gc-leaf decl; `@bad` calls a non-leaf decl; `@up` calls `@bad`; `@a`↔`@b` cycle with no poison | `@leaf`, `@mid`, `@a`, `@b` stamped; `@bad`, `@up` not |
| `gcfree_plan_markers.mlir` | functions calling a cursor marker, `__eco_list_tail_inline`, `__eco_sat_begin`, a libm `sqrt`, `llvm.` intrinsic decl | cursor and libm and intrinsic stamped; tail and sat not |
| `gcfree_plan_covered.mlir` | forged cap plan; covered `@c` with `__eco_alloc_inline`; non-covered `@n` with a marker; non-covered `@k` calling `@c` | `@c` stamped; `@n`, `@k` not |
| `gcfree_plan_addressof.mlir` | `addressof @leafdecl` called with a mismatched type (gc-leaf decl) and `addressof @nonleafdecl` | first stamped, second not |
| `gcfree_plan_no_marker_row.mlir` | call to `__eco_bogus_inline` | `not`; "marker without a table row" |
| `gcfree_plan_local_check.mlir` (`-emit=llvm`) | forged `eco-gcfree-plan` flag; a stamped definition calling a non-leaf decl | `not`; "stamped function 'f' calls 'g', which may GC" |
| `gcfree_plan_cov_without_cap.mlir` (`-emit=llvm`) | forged `eco-gcfree-plan` with `cov=1` and no cap plan | `not`; "cov=1" error text |

Forged-plan fixtures carry `// UNSETENV: ECO_GCFREE_VALIDATE ECO_CAPHOIST_VALIDATE`.

**Gates** (`ulimit -c 0`, each run once, output to a file):
1. **Byte-identical ELF:** lower `eco-compiler-boot.mlir` with the pre-change
   `eco-boot-native` (saved copy) and the new one; `cmp`.
2. **Validate on the self-compile:** `ECO_GCFREE_VALIDATE=1 ECO_CAPHOIST_VALIDATE=1`;
   `mlir_only=0`, and `llvm_only` explained.
3. **`check`** with both validate variables exported: previous count + new fixtures.
4. **`stress`** with validate.
5. **`run-aot-e2e`** with validate: 899/901 (FlagsRecordTest, PortEchoTest).
6. **Env matrix,** validate on, lowering the self-compile once each (soundness, plus
   identity where noted): `ECO_ALLOC_HOIST=0`, `ECO_ALLOC_HOIST=c`, `ECO_GCFREE_LEAF=c`,
   `ECO_GCFREE_MLIR=0` (old path, identity), `ECO_KERNEL_GCLEAF=0`, `ECO_VALUE_EQ_GCLEAF=1`,
   `ECO_CAP_INLINE_MAX_INSTS=0`. JIT kind and -O0 are covered by `check` (JIT fixtures,
   `ecoc`).
7. **Bootstrap:** 4b/8c fixed points, 9b OK.
8. **Timing:** the new MLIR pass, and the step-13 phase (which should drop to the
   declaration assert).

## Q9. Invariant text

- **CGEN_072:** the producer is `EcoGcFreePropagation` (MLIR, last pass of
  `buildEcoToLLVMPipeline`), reading the shared marker table's final view and 01's
  `eco-cap-covered`, recording `eco-gcfree-plan`. The LLVM fixpoint remains the producer
  only for modules without that flag, and is the validate twin otherwise. Every stamped
  definition is checked pre-RS4GC (local check, independent of `hasGC`), and every
  cross-partition gc-leaf declaration must have a stamped owner (X). `Utils_equal` is
  stamped through the (f) switch; arm-3 leafness is the planned `veq`. Scratch helpers
  stay name-stamped by the backend.
- **CGEN_074:** compute-mode Phase A tests a generated defined callee before gc-leaf, so
  it is stamp-agnostic. The R2 mirror applies to the transform only.
- **CGEN_077:** `EcoGcFreePropagation` never writes `eco.callee_gc_leaf`.


## Implementation results (2026-10-02)

J1–J8 were built as specified, with one deviation the gates forced.

**The E6 hole (found while gating, now fixed).** Plan 02 stamps definitions *before* capacity
hoisting runs. A type-mismatched call through `addressof` has no `getCalledFunction()`, and
`callsGCLeafFunction` reads gc-leaf off the called operand with no type check. So such a call
to a stamped definition read as transparent in Phase A/D/D2, where it used to be a breaker.
That was unsafe: ⊤ ∧ GC-free is **not** empty, because a function that calls a headroom
breaker is gc-leaf but ⊤ (Part I assumed otherwise). A GC-free callee can still consume
nursery headroom, so merging two runs across it voids the ensure.
- **Fix:** `leafForAnalysis` (`EB`). A non-direct call whose operand is a generated function
  (defined, or carrying eco-cap facts) is never leaf for hoisting or for the gc-free twin.
  RS4GC keeps the literal predicate, which is sound because the target cannot GC.
- **Detection:** it showed up as 98 differences in 01's validate twin (`plan top vs compute
  budget=24`).
- **Pinned by:** `gcfree_plan_mismatched_breaker.mlir`. With the fix reverted, that fixture's
  function gets a single 40-byte ensure.

**Other notes:**
- The JIT's `_mlir_*` wrappers are created after the plan pass, so they are no longer stamped.
  They have no GC strategy and nothing calls them from generated code.
- 01's per-call marker walk (P6.6) was replaced by the declaration assert (`checkMarkerDecls`).
- The 01 pass now reads `ECO_VALUE_EQ_GCLEAF` through the shared helper, which only accepts
  `1`, as the backend does.

**Gates** (`ulimit -c 0`; both validate switches exported for 2–6):

| # | Gate | Result |
|---|---|---|
| 1 | Self-compile ELF vs pre-change `eco-boot-native` (`stats-backend-opt/eco-boot-native.pre02`) | byte-identical |
| 2 | Validate, self-compile | `mlir=8558 llvm=8558 mlir_only=0 llvm_only=0`; 01 twin 75,775 compared, 0 diffs; (X) 24 partitions, 196,673 cross-partition gc-leaf declarations checked |
| 3 | `check` | 2022 passed / 0 failed (2014 + 8 fixtures); 1234 validated modules, `mlir_only` 0, `llvm_only` 2969 = JIT `_mlir_*` wrappers only |
| 4 | `stress` | 101 / 101 |
| 5 | `run-aot-e2e` | 899 / 901; the 2 failures are the known FlagsRecordTest and PortEchoTest. The first attempt failed 865 tests at Elm→MLIR with "CORRUPT CACHE": stale per-test `eco-stuff` caches after the front end was rebuilt. Moving them aside fixed it; this is not a codegen issue |
| 6 | Env matrix (self-compile, validate) | every arm `mlir_only=0 llvm_only=0`: `ECO_ALLOC_HOIST=0` 3485, `=c` 3485, `ECO_KERNEL_GCLEAF=0` 8522, `ECO_VALUE_EQ_GCLEAF=1` 8871, `ECO_CAP_INLINE_MAX_INSTS=0` 9459. `ECO_GCFREE_LEAF=c` and `ECO_GCFREE_MLIR=0` take the LLVM path; `ECO_GCFREE_MLIR=0` is byte-identical to the pre-change ELF |
| 7 | Bootstrap | 4b and 8c fixed points, 9b OK (14 min 06 s, Stage 5 re-ran in 7:01) |
| 8 | Timing (Stage 6) | `EcoGcFreePropagation` 0.25 s (MLIR, parallel scan); `gc-free leaf propagation (serial)` 293 ms → **8.85 ms**; `capacity-hoist analysis` 988 → 940 ms (declaration assert instead of the per-call walk); Stage 7b 44.93 s |

## Adversarial review (2026-10-02)

Every citation was checked against the code. Most hold (line drift ≤ 5). The issues below
were found, and the plan above has been corrected in place.

| # | Issue | Evidence | Addressed |
|---|---|---|---|
| R1 | **O1 covered only Phase D/D2.** Phase A tests `callsGCLeafFunction` before the defined-callee edge. A stamped covered callee then drops out of the caller's budget, the caller can become covered, and §2.6(a)/(b) both still pass. That is silent headroom corruption in any LLVM Phase A on stamped IR: the validate twin, 01 §4.3, or full hoisting after MLIR stamping | `EB:3026-3035`, `3427-3443`, `3461-3471`; 01 §3 table | O1 extended. The LLVM full hoisting hard-errors on stamped definitions. §8 updated |
| R2 | **O1's mitigation was self-contradictory.** "Transparent only when budget 0" is 01's R3′ (an output change), but O1 claimed it "restores today's decisions exactly". Today an unstamped budget-0 callee is a **breaker** (01 R3). Also, "generated = has `eco-cap-budget`" missed `eco-cap-top` decls and any decl whose eco-cap copy was lost | `EB:3285-3302`; 01 §3 R1/R3, §4.2 | Rule rewritten to 01's R1/R3. New F11 plus a trusted-set assert: a gc-leaf decl without `eco-cap-*` must be a runtime/kernel name. `eco-cap-top` added to the O4 whitelist |
| R3 | **O5 facts wrong.** CGEN_072(a) does not list `Utils_equal` as poison; it defers to (f), and the KernelFacts row is A1. The real conflict is the hard-coded `gcLeaf=true`, which bypasses `ECO_KERNEL_GCLEAF=0` (F4's bisection switch). Also, `eco.value.eq` **is** emitted, under `ECO_VALUE_EQ` / `ECO_VALUE_EQ_STRCASE`; the `EB:2364` comment is stale | `EcoToLLVMRuntime.cpp:940`; `EcoToLLVMFunc.cpp:43-51`; `KernelFacts.elm:434`; `EcoControlFlowToSCF.cpp:816/863`; `EcoToLLVMControlFlow.cpp:425`; `Config.elm:745` | O5, §1.5, §9 Q1 corrected; switches added to the step-4 matrix and F10 |
| R4 | **O6 "inlining preserves the result" holds for soundness, not equality.** `CloneAndPruneFunctionInto` drops arms that are dead under constant actuals, and actual substitution turns `call %arg` direct. So S_llvm can strictly exceed S_mlir. Step 4's `==` and step 5's byte-identity could fail on safe diffs | AlwaysInliner at `EB:3631`; LLVM InlineFunction | O6 rewritten; M6 added; step 4 now requires ⊆ with S_mlir ⊄ S_llvm fatal; fallback options listed |
| R5 | §1.3(c) / §5.2 treated any `llvm.*`-named callee as leaf. LLVM uses `getIntrinsicID()` (unknown names are not leaf) and excludes statepoint, deoptimize and the element-atomic memcpy/memmove. The poison rule also only named `llvm.invoke`: `llvm.inline_asm` and other `CallOpInterface` ops were unhandled | LLVM `Local.cpp` `callsGCLeafFunction`; `EB:348` (inline asm only in census) | §1.3(c), §5.2 tightened |
| R6 | The E6 asymmetry (gc-leaf read through the called operand with no type check) was not emulated for mismatched-type `addressof` calls to gc-leaf **declarations**: a conservative validate diff | §1.3(a); 01 §2.4 | O7 bullet; M7 |
| R7 | The table needed three views, not two. The declared bit ≠ the hoisting view (list-tail is declared leaf but is ⊤ for 01). 01 §2.2 wrongly lists the cursor markers as "MLIR decl, gc-leaf" | `EcoToLLVMRuntime.cpp:693`; `EcoListCursor.cpp:103-111` | §5.1 columns; 01 inconsistency noted (01 not edited) |
| R8 | O10's `eco.gc_leaf` route moves the scratch stamps under `ECO_KERNEL_GCLEAF=0`. Today they are unconditional (`EB:3670`), and CGEN_072(f) scopes that channel to KernelFacts rows | `EcoToLLVMFunc.cpp:48/99`; CGEN_072(f) | O10 bullet |
| R9 | Missing gates: codegen fixtures that print llvm-dialect attributes will churn, and the env matrix lacked `ECO_GCFREE_LEAF=c/0`, STRCASE, the JIT kind, the prepass off, and barriers off | `test/codegen/*.mlir` (5 files grep `gc-leaf-function`) | Steps 4/5 extended |
| R10 | Missing consumer: EcoPtrIntVerify reads callee gc-leaf (validation builds) | `EcoPtrIntVerify.cpp:57` | §1.4 |
| R11 | Missing link: driver internalize + GlobalDCE runs between MLIR stamping and step 1. It is harmless, since no interposable linkage is emitted, and IPSCCP has funcspec off. Also, master §4.2 copies "passthrough" wholesale, which contradicts O4's whitelist | `EB:1287-1308`, `EB:535`; master §4.2 | §2 bullets; O4 note |

**Verified as stated:** the pipeline order and line numbers in §1.1; the assert/FP placement;
the CloneModule/`deleteBody` attribute survival; no `TailCallKind`/musttail emission (only
`EcoToLLVMClosures.cpp:2941` safepoint suppression); `__eco_init_globals` created after the
`eco-gc` stamping walk; hoisting `On` requires gcfree `Stamp` (`EB:3687`); the sat markers
are declared leaf and expand after hoisting; the cursor markers have no gc-leaf in MLIR;
O3's chain (a covered caller-of-covered is a run member with an ensure).

**Residual concerns (not resolved here):**
- The trusted-set assert (F11) needs a single authoritative runtime-name list. Today the
  names are spread across `EcoToLLVMRuntime.cpp`, the `getOrInsertFunction` sites in `EB` and
  the kernel stubs. Step 1's table should own it, or the assert will rot.
- M6 is unmeasured. If inlining-only frees are common, the step-5 identity gate needs a
  new baseline. If an additive LLVM stamper is kept, CGEN_072 gets two producers again.
- 01's Q3 (a sat bracket whose slow sequence holds no non-leaf call) stays latent. 02 is
  conservative there (Always), but the §5.2 budget-0 cross-check would fire on it.
- `ECO_KERNEL_GCLEAF=0` remains an incomplete bisection switch until R3's fix lands.
