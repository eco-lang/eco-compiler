# Plan: Demand-driven specialization of `let`-bound `number` values

**Status:** PROPOSED (design grounded in code investigation; one verification spike, Phase 0, gates implementation)
**Component:** Compiler — monomorphizer (`Compiler.Monomorphize.Specialize`)
**Fixes:** `let-number-misspec-error.md` — a `let`-bound, unannotated `number` used at `Float` is
mis-specialized to `Int`. Reproduced by the 34 `test/elm/src/LetNumber*Test.elm` regression tests
(crash, invalid-MLIR, and silent-`0` variants).

---

## 1. Root cause (recap)

A `let`-bound `number` is let-generalized (`∀. number`). The binding is monomorphized **eagerly,
before its body is specialized** (`Specialize.elm:2731`, the non-lambda `_ ->` Let branch), via
`applySubstFV state subst defCanType`. Because nothing has yet told the binding that a consumer
wants `Float`, `applySubst` defaults the unresolved `CNumber` var to `MInt`
(`TypeSubst.elm:632`). The operator/consumer is independently specialized to `Float`. The two
disagree → kernel-signature crash (direct Float kernel), invalid MLIR (intrinsic), or — when the
value is boxed in a tuple/record/list/Maybe — a silent miscompile (i64 slot read as f64 ≈ 0).

The asymmetry: a **top-level** `number` works because `VarGlobal` is specialized per-use from
`meta.tipe` (`Specialize.elm:1707`); a **local** is read from `varEnv` (the binding's already-decided
`MInt`, `Specialize.elm:1673`).

---

## 2. Key findings from investigation (these shape the design)

1. **`Mono.forceCNumberToInt` is now the identity function** (`Monomorphized.elm:265`). The real
   `CNumber → MInt` defaulting moved *inside* `applySubst`/`resolveMonoVars`
   (`TypeSubst.elm:632`, `:531`). Consequence: the recipe **"bind the `number` var to `MFloat` in
   `subst` *before* `applySubstFV` runs → the result is `MFloat`"** is sound, and is *already* the
   mechanism the `TOpt.Int` literal case relies on (`Specialize.elm:1636-1649`: `applySubstFV` then
   `case … of MFloat -> LFloat`). Verified.

2. **The vehicle for "consumer → operand back-propagation" already exists.** `TOpt.Call` uses
   two-phase argument processing (`Specialize.elm:1895`): `processCallArgs` (phase 1) can **defer** an
   argument, and `resolveProcessedArg` (phase 2) resolves a deferred arg against the callee's resolved
   `paramType`. Precedents: `PendingAccessor` (resolved against a record paramType, `:3537`),
   `PendingCall`, `PendingGlobal`, `LocalFunArg` (`ProcessedArg`, `:59-64`). **A plain `VarLocal`
   operand is the one case that is *not* deferred** — it is specialized eagerly via `specializeExpr`
   (`:3415-3423`) → reads `varEnv` → `MInt` → `ResolvedArg`, *before* the operator's
   `paramTypes = [Float, Float]` are known (`:2035`). That eager resolution is the bug at the use site.

3. **The `applySubstKeepNumber` trick is already in production for the sibling case.** The
   `PendingGlobal` branch (`:3479-3491`) keeps an unresolved `number` arg as an `MVar CNumber`
   (not `MInt`) specifically so a concrete sibling arg can pull it to `Float` through
   `unifyCallSiteDirect` — exactly the case "`Array.foldl (+) 0.0 arr`" cited in its comment. This
   proves the kernel ABI derivation resolves `Basics.mul`/`add`/… to `Float → Float → Float` when one
   operand is `Float` *and the other is a preserved `CNumber` var* — which is the state we need the
   deferred operand to be in.

4. **Per-use freshening is real and the read side already works.** `p` in `let p = (30,99) in
   Tuple.first p * 1.5` is let-generalized; each use instantiates fresh `number` vars. The projection
   `Tuple.first p` is a `Call` whose result node carries the solver-resolved **`Float`**
   (writeback `Build.elm:108`; PostSolve treats Call/Access/VarLocal as "trust solver type"). So the
   **read** resolves to `Float` correctly. The bug is purely on the **construction** side: `p`'s
   binding builds slot 0 as `i64` because the binding-side var (decoupled from the use by
   generalization) defaults to `Int`.

5. **Codegen is sufficient — no MLIR/heap changes needed.** Tuple/record/ctor slot representation
   (`encodeUnboxedKind`, `Types.elm:454`: `MInt→i64`, `MFloat→f64`) and projection result types
   (`monoTypeToAbi resultType`) are *both* derived from the MonoType the monomorphizer assigns. If the
   monomorphizer emits a consistent `MFloat` at construction **and** read, the slot is `f64` at both
   ends and the bug disappears end-to-end. The two codegen "punts" (`Expr.elm:1228`, `Ops.elm:481`)
   are guard rails that only fire on the *mixed* `[MFloat, MInt]` the bug produces; they go silent once
   mono is fixed. GC reads the same MonoType-derived header bitmap, so consistency is automatic.
   (Invariants `REP_HEAP_002`, `HEAP_019`, `REP_BOUNDARY_001`.)

6. **`refineSubstFromArgExprs` (`:3337`, wired at `:1909`)** already back-propagates *container element*
   types from arg expressions into `subst` (e.g. `a = MInt` from a `List Int` arg). It is the closest
   existing analogue of what we need, but it runs on the **eagerly-computed** `argTypes`, so for a
   bare operand it would see `MInt` and push `MInt`. We must keep the operand as `CNumber` (finding 3)
   so this does not prematurely pin it.

**Net:** the design is not a green-field mechanism. It is "make a `number` `let` behave like the
deferred bindings and deferred call-args that already exist," plus the un-gated projection recording
the `valueMulti` path already performs for boxed `a`.

---

## 3. Design overview

Two cooperating changes, unified by **deferring the binding** so use-site demand can reach it:

- **A. Defer the binding.** Route a non-lambda `let` whose type contains an unresolved `CNumber`
  var through the existing demand-driven deferral (`ValueMultiState` stack), instead of the eager
  `_ ->` branch. The body is specialized first; the binding is emitted **once per recorded instance
  type**, re-derived from `info.subst` (the `valueMulti` emission loop, `:2645-2725`, already does
  exactly this).

- **B. Record instances from the uses.** Three recording sites feed the deferred binding's
  `info.subst` with the resolved numeric type the consumer demands:
  1. **Call-arg operand** (new) — covers the **bare operand** (`1.4 * n`), **function-style
     projection** (`Tuple.first p`, whose callee paramType resolves to `(Float, β)`), and
     **whole-value-to-function** (`useTuple p`, paramType `(Float, Float)`). All three are "deferred
     operand resolved against the callee's `paramType`."
  2. **Record access** `r.field` — the `TOpt.Access` path (`:3006`) already does this for
     `valueMulti`; ensure it fires for number-deferred entries.
  3. **Pattern destructure** — the `TOpt.Destruct` path (`:2794`) already does this; ensure it fires
     for number-deferred entries.

Then at emission, `applySubstFV (defCanType) info.subst` yields `MFloat` (or `(MFloat, MInt)`, …) by
finding 1; construction emits `f64`; codegen is unchanged (finding 5).

Why this unifies the "two cases" from the bug doc: the doc's §7.2 "operator back-propagation" *is*
"resolve the deferred operand against the operator's param type." The §7.1 attempt failed because it
recorded at the **eager** `VarLocal`/`specializeExpr` site (which reads `varEnv`), not by **deferring**
the operand to `resolveProcessedArg` where the resolved `paramType` is available. This plan fixes that
by deferral, reusing the `PendingAccessor`/`PendingGlobal` pattern.

---

## 4. Phase 0 — Verification spike (gates implementation)

Static reading leaves five load-bearing assumptions that a ~1-2 build/trace-cycle spike should
confirm before writing code. Each has a concrete check:

| # | Assumption | Check | If false |
|---|---|---|---|
| 0.1 | The bare operand `n` in `1.4 * n` is reached as a `TOpt.Call` arg with the operator a `VarKernel`/`VarGlobal` resolving to `Float→Float→Float`. | Add a trace in `processCallArg`'s `VarLocal` branch printing `name`, `localMeta.tipe`, and the enclosing func; compile `LetNumberFloatMulTest`. | Operand reached elsewhere → rework recording site. |
| 0.2 | Keeping the operand as `CNumber` (not eager `MInt`) lets `deriveKernelAbiType`/`unifyCallSiteDirect` resolve the operator to `Float→Float→Float` (sibling `1.4` forces it). | Trace `funcMonoType`/`paramTypes` at `:2030`/`:1996` with the operand forced to `applySubstKeepNumber`. | Operator stays mixed → need explicit operator-arg back-prop, not just keep-number. |
| 0.3 | `Tuple.first p`'s callee paramType resolves to `(Float, β)` at the call (via `unifyCallSiteDirectWithExpected … (Just canType)`, `:1985`). | Trace `paramTypes` for the `Tuple.first` call in `LetNumberTupleBothTest`. | Projection paramType stays polymorphic → recover slot index from the projection function name instead. |
| 0.4 | The `valueMulti` emission loop (`:2645`) correctly re-specializes a **non-lambda data def** (a tuple/record/scalar literal) under a refined `subst`. | Manually route one number let through the existing loop in a scratch build; inspect emitted MonoDef. | Emission assumes lambdas → add a data-def emission variant. |
| 0.5 | `Compiler.Monomorphize.Specialize` is the live monomorphizer on the AOT/native path (not `Compiler.Generate.Monomorphize`, which the `abs` analysis cites). | Grep the build entry / add a `Debug.log` at the `Let` dispatch; confirm it fires for an AOT compile. | Port the change to the live pipeline. |

The spike is instrument-and-observe only (no production code changes); it converts the
medium-confidence items in §8 to high.

### Phase 0 — RESULTS (executed; all assumptions VALIDATED)

Method: 0.4/0.5 settled by reading; 0.1/0.2/0.3 by instrumenting the two `TOpt.Call` branches with
`Debug.log` probes (eager `argTypes`, derived `paramTypes`, and a keep-number counterfactual),
rebuilding guida (`cmake --build build --target guida`), and compiling `LetNumberFloatMulTest`
(`1.4 * n`) and `LetNumberTupleBothTest` (`Tuple.first p` / `Tuple.second p`). Probes reverted and
guida rebuilt clean (original crash restored, source back to 4826 lines, 0 residual probe refs).

- **0.5 — VALIDATED.** `Compiler/Generate/Monomorphize.elm` does **not exist** (the `abs` analysis
  cited a stale path). The only monomorphizer is `Compiler.Monomorphize.Monomorphize` (imported solely
  by `Builder/Generate.elm`), which calls `Specialize.specializeNode` (`Monomorphize.elm:413`).
  `Specialize.elm` is the live AOT pipeline. ✓
- **0.4 — VALIDATED.** `specializeDef` for `TOpt.Def` (`:3832`) is just `specializeExpr expr subst
  state` — agnostic to lambda vs data literal. Under a refined `subst`, the `Int`-literal case
  (`:1636`) emits `LFloat`. The existing emission loop re-specializes a tuple/scalar def correctly. ✓
- **0.1 — VALIDATED.** For `1.4 * n`, observed at the call:
  `argTypes = [MFloat, MInt]` (operand `n` eagerly defaulted to `MInt` — the bug),
  `paramTypes = [MFloat, MFloat]` (operator resolved to Float). The resolved `Float` for the operand
  slot **is already present at the call site, in `paramTypes`.** ✓
- **0.2 — VALIDATED (stronger than assumed).** `Basics.mul` resolves to `paramTypes = [MFloat,
  MFloat]` **even with the operand eagerly `MInt`**, because it takes the polymorphic-global path whose
  `unifyCallSiteDirectWithExpected … (Just canType)` (`:1985`) unifies against the **expected result
  type** (`Float`), forcing `number = Float`. So the `Float` paramType does not depend on the
  keep-number trick at all (see Bonus B1). ✓
- **0.3 — VALIDATED (precise).** `Tuple.first p` → `argTypes = [MTuple [MInt, MInt]]` (operand `p`
  eagerly all-Int — the bug), `paramTypes = [MTuple [MFloat, MInt]]`. `Tuple.second p` →
  `paramTypes = [MTuple [MInt, MFloat]]`. **The callee paramType pinpoints exactly which slot the
  consumer demands at `Float`.** ✓

### Bonus findings (refine the design)

- **B1 — `+ - * /` are `Basics` *globals*, not `VarKernel`s, at the call site.** They route through the
  polymorphic `VarGlobal` path (`:1978`), where `unifyCallSiteDirectWithExpected` derives `paramTypes`
  from the **expected result type**. The kernel `Elm_Kernel_Basics_mul_Float` appears only *inside* the
  specialized global body. Consequence: the bare-operand fix does **not** need `applySubstKeepNumber`
  to obtain `Float` — the resolved `Float` paramType is already there. Keep-number is now demoted to a
  *defensive* measure: it prevents `refineSubstFromArgExprs` (`:1909`) from prematurely pinning the
  operand to `MInt`, and covers any numeric op that genuinely *is* a `VarKernel`. (Verify in Phase 2
  which numeric ops, if any, take the kernel path.)
- **B2 — the resolved *per-slot* container paramType is directly available** (e.g. `(Float, Int)` for
  `Tuple.first`). Phase 2's container recording reads the slot layout straight from `paramType` via
  `unifyExtend canType paramType` — no need to recover slot indices from projection-function names
  (Phase 3's function-style-projection concern dissolves).

### Reconciliation with the bug doc §7.1 / §7.2

The spike confirms the operand reference does **not** carry `Float` (it is eagerly `MInt`); the `Float`
lives in the **consumer's resolved `paramType`** — exactly the doc's §7.2 "operator
back-propagation." The §7.1 attempt failed because it recorded at the *eager* `VarLocal` site
(`specializeExpr` → `varEnv`), bypassing the `paramType`. This plan's vehicle —
**defer the operand to `resolveProcessedArg`, where `paramType` is available** — is the concrete,
already-precedented realization of §7.2.

---

## 5. Phase 1 — Defer `number`-carrying value lets

**File:** `Specialize.elm`.

1. New predicate `hasUnresolvedNumberVar : MVarEnv -> Can.Type MVarId -> Bool` — true if any free var
   of `defCanType` is a `CNumber` var (`State.isNumberVar`). This is the dual of `hasCEcoTVar`
   (`:400`), which currently *excludes* number vars.

2. Extend the Let dispatch (`:2542`, the `_ ->` arm). New gate:
   ```
   if shouldUseValueMulti … then            -- existing: lambda + CEcoValue
       <existing valueMulti path>
   else if hasUnresolvedNumberVar mvarEnv defCanType then
       <number-deferral path>               -- NEW, reuses ValueMultiState machinery
   else
       <existing eager path>                -- unchanged
   ```
   The number-deferral path is structurally the valueMulti path (`:2543-2729`): push a
   `ValueMultiState` entry, seed `varEnv` with the prelim type, specialize the body, then on pop emit
   one specialized def per instance (`:2645`) or fall back to eager if no instances were recorded
   (`:2578`). **Reuse `getOrCreateValueInstance`/`updateValueMultiStack` verbatim.**

   Rationale for reuse over a parallel `numberMulti` stack: `ValueInstanceInfo`
   (`State.elm:297`) already carries exactly `{ freshName, monoType (instance key), subst,
   derivedDestructorNames }`, and the emission loop already re-derives the per-instance type from
   `info.subst`. The only thing number needs that lambdas don't is the call-arg recording site
   (Phase 2).

**Caveat (finding 6 / agent-3):** the prelim `varEnv` seed must keep the binding's `CNumber` var
*unresolved* where possible, so that a use that reaches the new call-arg recording site is not
pre-pinned. Use `applySubstKeepNumber` for the prelim seed type rather than `applySubstFV`.

---

## 6. Phase 2 — Record instances from call-arg operands (the new recording site)

**File:** `Specialize.elm`, `processCallArg` (`:3374`) and `resolveProcessedArg` (`:3526`).

1. New `ProcessedArg` variant: `PendingNumberValue Name (Can.Type MVarId)` (mirrors `LocalFunArg`).

2. In `processCallArg`, the `VarLocal`/`TrackedVarLocal` branches (`:3400`, `:3425`): add, *before*
   the eager `else`, a check `isNumberMultiTarget name st` (a deferred number binding is on the
   `valueMulti` stack). If so:
   ```
   ( PendingNumberValue name localCanType :: accArgs
   , TypeSubst.applySubstKeepNumber st.ctx.mvarEnv subst localCanType :: accTypes   -- keep CNumber, finding 3
   , st )
   ```
   Keeping `CNumber` in `accTypes` is now **defensive** (per spike result B1, the `+ - * /` globals
   already resolve `paramTypes` to `Float` via the expected-result path, with the operand eagerly
   `MInt`): it prevents `refineSubstFromArgExprs` (`:1909`) from prematurely pinning the operand to
   `MInt`, and covers any numeric op that genuinely takes the `VarKernel` path (where the
   `applySubstKeepNumber` precedent at `:3491` is load-bearing).

3. In `resolveProcessedArg` (`:3532`), new case for `PendingNumberValue name canType` with
   `maybeParamType`:
   - If `maybeParamType` is a concrete numeric scalar (`MFloat`/`MInt`) or a container whose relevant
     slot is concrete: `unifyExtend mvarEnv canType paramType subst` to bind the operand's
     `number` var(s) to the resolved type (finding 1 makes this yield `MFloat`).
   - Derive the resolved instance MonoType and `getOrCreateValueInstance name instMonoType
     refinedSubst` to record the instance on the deferred binding (Phase 1).
   - Emit `Mono.MonoVarLocal instanceFreshName instMonoType`.
   - If `maybeParamType` is absent/polymorphic, fall back to the eager resolution (default `Int`) — a
     documented residual gap (§7).

   This is the `PendingAccessor` resolution (`:3537`) generalized from "record paramType" to "numeric
   scalar or numeric-slot container paramType."

**Ordering caveat (agent-3, finding):** `unifyExtend` is *last-writer-wins*, not monotone, on
conflict. Ensure the `Float` binding is not subsequently overwritten by a sibling `Int` unification
on the *same* var. Per-use freshening normally isolates vars, but assert/trace this in tests with two
uses (`LetNumberRecordMultiFieldTest`, `LetNumberFracRecordTest`).

---

## 7. Phase 3 — Un-gate projection/destructure/access recording for number

**File:** `Specialize.elm`. The `TOpt.Access` (`:3006`) and `TOpt.Destruct` (`:2794`) paths already
call `getValueMultiVar`/`getValueMultiRootFromPath` and record instances. Because Phase 1 reuses the
`valueMulti` stack, these *already* recognize number-deferred entries — verify they record a numeric
slot type rather than bailing. `getValueMultiRootFromPath` already walks `Index`/`Field`/`ArrayIndex`/
`Unbox` (`:456`), so tuple-index and record-field destructuring are covered. **Function-style
projections** (`Tuple.first`/`second`, `List.head`) are *not* `Access`/`Destruct` nodes — they are
covered by Phase 2 (they are `Call`s whose operand `p` is a `PendingNumberValue` resolved against the
projection's paramType).

---

## 8. Phase 4 — Emission, defaulting, and exhaustiveness

- **Emission:** unchanged from the valueMulti loop (`:2645`). Per instance:
  `instanceDefMonoType = applySubstFV stateAfterBody info.subst defCanType` (`:2663`) → concrete
  (`MFloat`, `(MFloat, MInt)`, …); `unifyExtend` bridges binding vars to the instance monotype
  (`:2667`); `specializeDef` re-emits the RHS (literal/tuple/record) with `f64` slots.
- **Defaulting of untouched slots is safe:** a slot no consumer projects stays `Int`. Construction and
  the (zero) reads agree, and GC reads the same bitmap. Soundness holds because each generalized use is
  independent; distinct demanded layouts produce **distinct instances** (keyed by container monotype),
  i.e. the value is *duplicated* per layout and each use is routed to its copy — correct under Elm's
  structural (not reference) equality.
- **`enqueueSpec` assertion risk (agent-1):** the `speckey-container-aware-specialization` work wants
  to crash on residual `CNumber` at `enqueueSpec`. Ensure every emitted number instance is fully
  resolved (no `MVar CNumber` left) before enqueue, or the assertion trips. The fallback in Phase 2
  (polymorphic paramType → default Int) guarantees groundness.

---

## 9. Known gaps (document, don't silently miss — bug doc §5 lists silent miscompiles as the danger)

1. **Aliasing**: `let q = p in Tuple.first q` — `q`'s RHS is a bare `VarLocal p`. Recording on `q`
   does not propagate to `p`'s construction. Out of scope (matches `destructor-call-subst-to-valuemulti`
   decision D4). None of the 34 tests alias; add an `xfail` test to mark it.
2. **Polymorphic-number callee chains**: a number value passed to a user function that *itself* defers
   its `number` param creates a two-level demand chain. Phase 2's fallback defaults to `Int` if the
   callee paramType is not yet concrete. `LetNumberApplyToTest`/`MulFnTest`/`ScaleFnTest` exercise this
   — confirm the callee's paramType is concrete at the call (it is, when the callee is monomorphic at
   that site) or extend recording across the chain.
3. **Literals in non-`let` function bodies** (`abs-monomorphization-issue.md`): hardcoded literal types
   in `Optimize/Typed/Expression.elm:156` / `Generate/Monomorphize.elm:761` are a *separate* root cause
   not addressed here. Out of scope; cross-reference.

---

## 10. Risks & conflicts

- **Wrong pipeline** (Phase 0.5): if the live AOT monomorphizer is `Generate/Monomorphize.elm`, this
  plan targets the wrong file. Gate on 0.5.
- **`refineSubstFromArgExprs` double-binding**: it runs at `:1909` on `argTypes`. With the operand now
  `CNumber` (not `MInt`), confirm it does not bind the var to something wrong; it should simply not
  touch an unresolved var, or bind it consistently with the operator. Trace in Phase 0.2.
- **Performance**: deferring every number let adds a `ValueMultiState` push/pop per such let. Lambda
  valueMulti is already this cost and is fine; number lets are common but the body walk is the same
  one already performed. Expect negligible.
- **Interaction with `localMulti`** for `let`-bound *functions* returning `number` — unaffected (those
  take the `TLambda` branch, `:2319`).

---

## 11. Test matrix

All 34 `test/elm/src/LetNumber*Test.elm` must move from FAIL → PASS. Coverage by mechanism:

- **Bare operand → operator back-prop (Phase 2 scalar):** `FloatMulTest`, `FloatArithCrashTest`,
  `MulFnTest`, `NestedLetTest`, `LetInLambdaTest`, `CaseLetTest`, `IfBranchTest`, `LogBaseTest`,
  `NegateTest`, `Indirect{Dual,Identity,Foldl,TopFn,Capture}Test`, `Destructure…`.
- **Function-style projection / whole-value-to-fn (Phase 2 container):** `TupleSecondTest`,
  `TupleBothTest`, `TupleToFnTest`, `ScaleFnTest`, `RecordToFnTest`, `ApplyToTest`,
  `CustomTypeTest`, `UnionBranchTest`, `Foldr/Map2/SumMapTest`, `ArrayMapTest`, `ResultMapTest`,
  `Maybe{Chain,AndThen}Test`, `ListOf{Records,Maybe,Closures}Test`, `ClosureInRecordTest`.
- **Access / destructure (Phase 3):** `RecordMultiFieldTest`, `FracRecordTest`, `DeepNestRecordTest`,
  `BoxedSilentMiscompileTest`.

Add: an `xfail` aliasing test (gap 1). Run `cmake --build build --target full` (full E2E) — never
re-run; tee to `/tmp/test_output.txt`. Also run `TupleSlotBoxing*Test` to confirm no regression of the
CEcoValue boxed-slot fix.

---

## 12. Confidence (post-spike)

Phase 0 has been executed; every previously-medium item is now **VALIDATED** (§4 results). The design
direction is confirmed end-to-end:

- **High (was high, unchanged):** the `MFloat`-via-`subst` recipe (already in production at `:1636`);
  codegen sufficiency (fully traced + `TupleSlotBoxing*` coverage).
- **High (promoted from medium-high by 0.1/0.2/0.3):** the consumer's resolved numeric type — scalar
  `MFloat` for `1.4 * n`, per-slot `(MFloat, MInt)` for `Tuple.first p` — **is present at the call in
  `paramTypes`**, so the deferred-operand-resolved-against-`paramType` mechanism has the right type to
  record. The `TupleBoth` case resolves to two instances `(Float,Int)` / `(Int,Float)` (duplication),
  both correct.
- **High (promoted from medium by 0.4/0.5):** the live monomorphizer is `Specialize.elm`; the emission
  loop re-specializes non-lambda data defs.

**Residual risk is now implementation-level, not design-level:** (1) `unifyExtend` last-writer-wins
ordering when two slot demands touch related vars (§6 caveat); (2) the `enqueueSpec` crash-on-residual-
`CNumber` assertion from the speckey work (§8); (3) the documented aliasing / chained-callee gaps (§9);
(4) confirming whether any numeric op takes the `VarKernel` path so keep-number is needed there (B1).
None of these threaten the approach; they are coding details to handle and test.

**Recommendation:** proceed to Phases 1-4. The spike converted the design from "credible direction with
load-bearing unknowns" to "validated mechanism with a clear implementation surface."

---

## 13. Implementation results

Implemented in `Compiler/Monomorphize/Specialize.elm`. Outcome on the full JIT E2E suite:
**491 elm tests — 482 pass, 9 fail (all `LetNumber*`); 100/100 stress tests pass; ZERO regressions**
in any pre-existing test. LetNumber coverage: **29/38 pass** (was 0/38).

### What shipped (differs from the original Phases 1-4)

The validated mechanism (defer + record use-site numeric type) is correct, but routing *every*
number-carrying let through it regressed ~11 existing tests. The regressions came from number values
that are **boxed / compound / nested / poly-sourced**, where the eager path was already correct and the
value-multi seeding + keep-number corrupts the boxed representation (SIGSEGV, `i64 != ptr`, garbage
HPointers). Phase 0 only probed the happy-path mechanism, so it did not surface these.

Two additions beyond the plan made the fix **zero-regression**:

1. **Eager-first emission, not full deferral** (§5 revised). The number let's def is specialized
   *eagerly first* (preserving `localMulti` recording order in its RHS), then the value-multi stack is
   *seeded* with that eager (default-Int) instance and the body specialized; only *additional Float*
   instances are emitted as extra copies. Int/boxed uses resolve to the eager instance. A
   `localMultiInstanceCount` delta check falls fully back to plain eager when the RHS drove local-function
   specialization. (`resolveNumberMultiVarRef` records only Float-bearing reference demands.)

2. **Two gates** restrict firing to provably-unboxed numeric bindings:
   - `isNumericFixableShape` (eager MonoType): scalar, or a **fully-recursive** tuple/record/list of
     numbers, or `Maybe`/`Result`/`Array` of numbers. (The depth was originally bounded to 2 levels;
     making it fully recursive is safe — the RHS gate independently excludes the deep-nesting
     regressions — and recovered the nested `{xs:[30]}` boxed-silent variant.)
   - `isNumericDataRhs` (the RHS expr): a literal, a numeric aggregate, a `numericDataOpNames`
     arithmetic call, a constructor application, or a number-multi alias. This is the **provenance**
     gate: it excludes `case`/`if`/general-function-call RHS, whose result may have originated boxed
     (`let r = case m of Just x -> x`, `let r = polyFn …`) — re-typing those is what caused the
     SIGSEGVs.

### Mechanism pieces (as built)

`hasUnresolvedNumberVar`, `isNumberMultiTarget`, `recordNumberInstanceAgainstShape` (unifies the
binding's `defCanType` against the consumer's resolved shape — robust to use-site/binding MVarId
divergence), `resolveNumberMultiVarRef` (non-call-arg references), `PendingNumberValue` ProcessedArg
(Phase 2 call-arg recording), the `TOpt.Access` number branch (Phase 3), and the eager-first number
branch in the `Let` dispatch. Codegen unchanged (Phase 0 finding 5 held).

---

## 14. The 9 remaining cases — root causes and required fixes

Confirmed via a `NUMFIRE` trace (what fires) + failure-mode inspection. Grouped by mechanism.

**A. User custom types — `CustomTypeTest`, `UnionBranchTest`.** `v = NumBox 30` has shape
`MCustom NumBox [MInt]`; `isNumericFixableShape` admits only `Maybe`/`Result`/`Array`, so `v` does not
fire → defaults Int → `case v of NumBox k -> k*1.5` reads i64 (`eco.float.mul operand i64`).
*Fix (two parts):* (1) admit user custom types whose numeric args are fixable in the shape gate;
(2) implement `HintCustom` in `buildPartialContainer` (currently returns `Nothing`, `Specialize.elm:~875`)
— synthesize `MCustom home name args` with the leaf at the field's type-arg position, which needs the
constructor's field→type-arg mapping (enrich the `Index` hint or look up the `Ctor` node).
*Effort: moderate; risk: medium (phantom-arg customs).* 

**B. `Result` with a non-numeric arg — `ResultMapTest`.** `res = Ok 30` has shape
`MCustom Result [e, MInt]`; the error `e` fails `isNumericFixableShape`, so `res` does not fire.
*Fix:* admit customs where only some args are numeric (the others phantom). *Risk: HIGH* — this is the
exact pattern (`number` phantom inside a boxed custom) that caused the `EmbeddedNothing`/`UnboxWrapper`
SIGSEGVs; needs the boxed-custom re-typing proven safe first.

**C. Closure capture of a number used at Float — `ClosureInRecordTest`, `ListOfClosuresTest`.** The
captured `n` fires (scalar), but the closure captures its **eager Int** layout while the body
(`\x -> x*n`) uses it at Float → runtime `SIGABRT: PK_Int evaluator with non-Int/Boxed desired_kind`
(`RuntimeExports.cpp:2003`). *Fix:* the closure-capture path must capture the Float instance and lay the
capture slot out as `PK_Float` (`_capture_abi` per-slot kind) — overlaps the
`type-aware-buildEvaluatorArgs-per-slot` work. *Effort: HARD (compiler capture path + runtime ABI).* 

**D. Container element type defaulting — `ListOfRecordsTest`.** `rs = [{n=30},…]` fires, but the
`List.map` call resolves `rs`'s paramType to `List {n: MInt}` — the map lambda's `{n:Float}` element
type never flows back to the `rs` argument (confirmed: recorded instance `MList (MRecord {n:MInt})`).
*Fix:* make the consumer's element type flow to the container argument — the documented
`speckey-container-aware-specialization` problem, upstream of this fix. *Effort: HARD (separate subsystem).* 

**E. Number through a control-flow operand — `IfBranchTest`.** In `(if n>0 then n else 0) * 1.5` the
`*` operand is the **`if` node**, not `n`. `n` (then-branch) records Float, but the `if` node's own
result type stays Int (its `meta.tipe` is `number`) and disagrees with the now-`f64` branch →
`coerceResultToType: cannot coerce f64 to i64`. Only `VarLocal`/projection/call-arg operands are
refined; an operand that is itself an `If`/`Case`/`let` over a number is not. *Fix:* defer
non-`VarLocal` number-typed call args (like `PendingCall`) and resolve the whole sub-expression against
the operator paramType so its branches+result unify to Float. *Effort: moderate-hard.* 

**F. Let-destructured tuple — `DestructureTest`.** `( a, b ) = ( 30, 40 )` desugars to a synthesized
`_v0 = (30,40)` (fires + seeded eager Int) + `Destruct a=Index0 _v0`, `Destruct b=Index1 _v0`. The
Destruct path *can* synthesize the tuple shape and record Float instances, but the **eager-first
seeding + Destruct-rewrite** bookkeeping doesn't connect `a`/`b` to the right per-slot Float copy → `a`
reads i64 (`mul_Float (i64, f64)`). *Fix:* reconcile the eager-first number branch with Destruct
value-multi recording (defer the tuple construction until the Destructs' demands are known, or retarget
the Destruct rewrite to the correct per-slot instance). *Effort: moderate-hard.* 

**G. Array builder RHS — `ArrayMapTest`.** `arr = Array.fromList [30,40]` — `Array.fromList` is a
function call, excluded by `isNumericDataRhs`. *Fix:* recognize specific container-builder functions
(`Array.fromList`, …) as data RHS. *Risk: low-medium* — must not admit arbitrary functions (the
poly-result class), so it needs an explicit builder whitelist (home `Array`), not a name match.

### Summary

The 9 split into: **gate-relaxable** (A-shape, B, G — easy gate change but B/A carry the boxed-custom
risk and A needs `buildPartialContainer`) and **mechanism gaps** (C closures, D container-element, E
control-flow operands, F let-destructure) that each touch a distinct subsystem, several overlapping
with separately-documented hard problems (capture ABI, container-element specialization). None is a
quick win; each is a scoped follow-up.
