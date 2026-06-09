# Plan: Thread consumer→producer numeric types for the remaining `let`-number cases

**Status:** PROPOSED
**Component:** Compiler — monomorphizer (`Compiler.Monomorphize.Specialize`), with two fixes touching the
typed-optimize phase (`Optimize.Typed.Expression`) and the runtime closure ABI.
**Builds on:** `let-number-demand-driven-specialization.md` (shipped: 29/38 LetNumber, zero regressions)
and the investigation `nul-let-hard-cases.md` (root causes + trace evidence for the 9 remaining
failures).

---

## 1. The principle these fixes share

`nul-let-hard-cases.md` established that all 9 failures are the same fact: **Elm let-generalizes a
`number` binding, the HM solver writes the resolved `Float` onto the _consumer_ node, and the
_producer/intermediate_ node keeps `number`→`MInt`.** The shipped fix threads the consumer's type to
the producer at exactly two sites — direct call-arg operands (`PendingNumberValue` resolved against the
callee `paramType`) and record access (`TOpt.Access`). Each remaining failure is an intermediate that
lives at a *different* site, so the same `Float` that is already present at monomorphization time is
never unified back onto the producer's `defCanType`.

So every fix below is one **threading edge**: *"consumer C carries `Float`; producer P needs it; thread
C→P via mechanism M."* The information is present in all cases (verified — see the cited traces); the
work is data flow inside monomorphization, plus one runtime-ABI consequence (closures).

The reusable threading primitive already exists: `recordNumberInstanceAgainstShape name shape subst`
unifies a resolved `shape` against the binding's `defCanType` and records the instance
(`Specialize.elm`). Each fix routes a new consumer type into it (or its analogue).

---

## 2. Fixes, by threading edge

### Fix 1 — Custom-type projection (CustomType, UnionBranch)

**Edge.** Consumer = the `case`-pattern variable `k`, whose node already carries the resolved `MFloat`
(trace: `DESTRUCT: { destrFieldMono = MFloat, dname = "k", rootFound = False }`). Producer = the let
`v = NumBox 30`. The type is on the node; two things block it.

**Mechanism (two parts, both in `Specialize.elm`).**
1. **Gate.** Relax `isNumericFixableShape` to admit an `MCustom home name args` *for any name* when its
   args are fixable (not just `Maybe`/`Result`/`Array`). The shape recursion already bounds it to
   numeric leaves; user customs whose only args are numeric (`NumBox [number]`) are exactly the safe
   set. (Keep the `isNumericDataRhs` provenance gate — `NumBox 30` is a constructor application, already
   admitted.) This makes `v` fire → `rootFound` becomes true.
2. **`buildPartialContainer` `HintCustom`** (`Specialize.elm:~875`, currently returns `Nothing`).
   Synthesize `MCustom home name args` with the leaf placed at the **type-arg position the field maps
   to**, fillers elsewhere. The field→type-arg map is not in the `Index` hint; look it up from the
   `Ctor` node's declared type (`Data.Map.get global state.ctx.toptNodes → TOpt.Ctor _ _ ctorCanType`),
   walk `ctorCanType`'s argument list to find which `TVar` the field index is, and place the leaf at
   that var's position in `args`. For `NumBox number` field 0 → arg 0; for `Pair number number` both
   fields → the single shared arg (so either field's Float sets the whole param). Reuse
   `unifyExtend rootCanType partialContainerMono` exactly as the tuple/record branches do.

**Prior art:** `fix-custom-type-field-type-registration.md` (the codegen-side ctor-field type
registry — needed so the emitted `eco.construct.custom` slot kind is `f64`; verify it already keys off
the MonoType `args`, else extend it). `fix-destructor-type-projection.md` (the destructor type already
resolves for case-patterns — confirmed by the `MFloat` trace — so no change needed there for this case).

**Risk:** medium — custom-type slot layout + `HintCustom` synthesis. **Effort:** moderate.

---

### Fix 2 — Control-flow operand push-down (IfBranch; Case operands by the same change)

**Edge.** Consumer = the operator `*`'s `paramType` (`Float`). Producer = the `then`-branch operand `n`,
*inside* an `if` that is itself the `*` operand. Trace: `IFNODE: { branchBodyMonos = [MInt],
finalMono = MFloat, ifResultMono = MFloat }` — the `else` literal and if-result resolved to `MFloat`, but
the `VarLocal n` branch stayed `MInt`, and the `if` node is specialized **eagerly** in `processCallArg`
(it is not a `VarLocal`, so it never reaches the `paramType`).

**Mechanism (`Specialize.elm`, mirrors the existing `PendingCall`).** Defer a non-`VarLocal`, number-
typed call operand instead of specializing it eagerly:
- In `processCallArg`, add a branch: for `TOpt.If`/`TOpt.Case`/`TOpt.Let` (and extend the existing
  `TOpt.Call` branch) whose provisional `monoType` contains an **unresolved CNumber var**
  (`containsNumberMVar`, the number analogue of the existing `containsCEcoMVar` gate at `:3458`), emit
  a `PendingCall arg subst canType` (reuse the variant; it is expr-generic) and a keep-number `accType`.
- `resolveProcessedArg`'s `PendingCall` branch already does the right thing:
  `unifyExtend canType paramType savedSubst` then `specializeExpr savedExpr refinedSubst`. Because the
  `if`-result var, the `then`-branch var and the `else`-branch var are unified to one var by inference,
  binding the if-result to `Float` (via `paramType`) re-specializes the branches at `Float` — `n` then
  records its `Float` instance through the existing `VarLocal` handler.

**Prior art:** `pending-call-nested-closure-specialization.md` (the `PendingCall` design; D2: it is
complementary to `refineSubstFromArgExprs`). `mono-case-branch-result-type-test.md` (the MONO_018
invariant this currently violates — the `MonoIf`/`MonoCase` result type must match its branches; this fix
restores it).

**Risk:** low-medium — re-specializing a deferred sub-expression is established; must keep the
`containsNumberMVar` gate tight so only genuinely-unresolved number operands defer (monomorphic
`if`s stay eager). **Effort:** moderate.

---

### Fix 3 — Destructor-bound number projection aliases (Destructure)

**Edge.** Consumer = the uses `a * 1.5`, `b * 1.5` (`Float` on the use nodes). Producer = the synthesized
tuple `_v0 = (30,40)` (which *fires*, trace `NUMFIRE { name = "_v0", shape = MTuple [MInt,MInt] }`), via
the destructor-bound vars `a`/`b`. The destructor field types are `MInt` (trace:
`DESTRUCT-REFINE { dname = "a", fieldMono = MInt }`) because `a`/`b` are *let-generalized* — so unlike
Fix 1, the Float is **not** on the destructor; it is on the uses of `a`/`b`, two hops from `_v0`.

**Mechanism (`Specialize.elm`).** Make a destructor-bound number variable a **projection alias** of its
root's value-multi instance:
- In the `TOpt.Destruct` case, when the root (`getValueMultiRootFromPath`) is a number-multi target and
  the bound var `a` has number type, register `a` in a new side table
  `numberProjAliases : Dict Name (Name, TOpt.Path)` mapping `a ↦ (_v0, Index i …)`.
- Make `isNumberMultiTarget a` consult that table (so `a` is treated as a number-multi target at its
  uses), and extend `recordNumberInstanceAgainstShape` so that for an alias it records the leaf shape at
  the aliased *slot* of the root: `buildPartialContainer (alias path) leafShape` → unify against `_v0`'s
  `defCanType` → record `_v0 = (Float, …)`. This reuses Fix-1's per-slot synthesis.
- Each of `a`/`b` records a different slot at `Float`; the eager-first emission then materialises the
  needed `_v0` instances (`(Float,Int)` for `a`, `(Int,Float)` for `b`) and the rewritten Destructs read
  the right copy.

**Interaction to resolve:** the shipped **eager-first** number branch emits `_v0` as `(i64,i64)` *before*
the body's Destructs are seen. For let-destructured tuples specifically, route `_v0` through the
*deferred* (not eager-first) emission so the Destruct-recorded Float instances are emitted — safe here
because a tuple literal RHS has no `localMulti` to scramble (the `localMultiInstanceCount` delta is 0).

**Prior art:** `fix-destructor-type-projection.md` (same Destruct/type-flow area; that fix addresses the
*generic-vs-inferred destructor type*, which is necessary if a future case has the Float on the
destructor — orthogonal but adjacent). `value-multi-specialization.md` (the destructor recording path
this extends).

**Risk:** medium — the alias table + eager-first/deferred routing for let-destructure. **Effort:**
moderate-hard.

---

### Fix 4 — Container element type flow (ListOfRecords; helps ArrayMap)

**Edge.** Consumer = the `List.map` lambda `\r -> round (r.n * 1.5)`, whose param type is `{n:Float}`.
Producer = the container `rs`. Trace: `PENDNUM { name = "rs", consumerParamType = MList (MRecord {n: MInt}) }`
— the consumer paramType the producer is resolved against has already **lost** the element's Float,
because `unifyCallSiteDirect` derived `List.map`'s element var from the *eagerly-typed* `argTypes` where
the record field defaulted to `MInt`. The Float exists on the *sibling* lambda argument, not on the
container paramType.

**Mechanism (`Specialize.elm`).** Push the sibling lambda's element type onto the container element
*before* the container's `PendingNumberValue` is resolved. Extend `refineSubstFromArgExprs` (`:3337`,
already wired at `:1909`) so that, for a known element-consuming combinator (`List.map`/`foldl`/`foldr`/
`filterMap`, `Array.map`/`foldl`, `Maybe.map`, `Result.map`), it unifies the **function argument's
parameter type** with the **container argument's element type** (`MList e` / `MCustom Array [e]` /
`MCustom Maybe [e]`). That binds `e`'s `number` var to the lambda's `{n:Float}`, so the subsequently-
derived `paramType` for `rs` becomes `MList {n:Float}` and the existing recording emits `f64` elements.

**Prior art:** `speckey-container-aware-specialization.md` and `container-element-specialization.md` —
this *is* that documented problem (helpers collapsing `List a` element types); align with their
`refineSubstFromArgExprs`/`containerSpecializedKernels` design rather than inventing a parallel path.

**Risk:** medium — touches the general container-element machinery used by all map/fold code, not just
numbers; must not change non-number element resolution. **Effort:** moderate-hard (and partly subsumed by
the speckey work if that lands first).

---

### Fix 5 — Container-builder RHS allowlist (ArrayMap)

**Edge.** Producer = `arr = Array.fromList [30,40]`; it never fires because `isNumericDataRhs` rejects a
*function call* RHS (no `PENDNUM` trace for `arr`). The provenance gate is correct to reject arbitrary
calls (the `polyFn` SIGSEGV class), but a *pure container builder* of numeric data is safe.

**Mechanism (`Specialize.elm`).** In `isNumericDataRhs`, admit `TOpt.Call (VarGlobal g) args` when `g`
is on a small **container-builder allowlist** keyed on the `Array` home + name (`Array.fromList`,
`Array.repeat`, `Array.initialize`) — **not** a bare name match (which would re-admit poly-result
functions named `fromList`). Then `arr` fires; its element type still depends on **Fix 4** to become
`Float`, so Fix 5 only completes the case in combination with Fix 4.

**Risk:** low (with the home-keyed allowlist). **Effort:** small; **depends on Fix 4.**

---

### Fix 6 — Closure use-site specialization + capture ABI (ClosureInRecord, ListOfClosures)

**Edge (two hops, and an ABI consequence).** Consumer = the application `rec.f 1.5` (`Float`). Producer =
the closure `\x -> x * n` *and its capture of `n`*. The closure is specialized as part of `rec`
(eager, excluded), so it is `Int -> Int`; the emitted MLIR shows `lambda$clo : (value, i64) -> i64`,
`eco.int.mul`, capture `unboxed_bitmap = 1` (n as `i64`), `_result_kind = 1` (PK_Int). Calling it at
`f64` hits the runtime assert `PK_Int evaluator with non-Int/Boxed desired_kind`
(`RuntimeExports.cpp:2003`).

**Mechanism (largest fix; spans three layers).**
1. **Use-site closure specialization.** The closure stored in `rec.f` must be specialized at its
   application type `Float -> Float`. This needs `rec` (record-holding-a-closure) to participate in
   use-site specialization — the `valueMulti`/`localMulti` domain — so the closure gets a `Float`
   instance. `closure-constraint-propagation.md`'s `specializeLambda` change (feed the use-site
   `monoType0` back via `unifyExtend` so the lambda's param + captured-var internal types are
   constrained) is the monomorphizer half: once the closure is requested at `Float -> Float`, `x` and
   the captured `n` resolve to `Float`.
2. **Number capture threading.** With `x : Float`, `x * n` demands `n : Float`; the existing `VarLocal`
   handler records `n`'s `Float` instance, and the capture operand becomes `f64`.
3. **Capture ABI.** `papCreate`'s `unboxed_bitmap` + `_operand_types` and the wrapper's `_result_kind`
   must follow the `Float` MonoType (`PK_Int → PK_Float`). This is `type-aware-buildEvaluatorArgs-per-slot.md`
   (per-slot capture kinds) + `typed-papextend-evaluator-return-type.md` (result kind).

**Prior art:** `closure-constraint-propagation.md`, `type-aware-buildEvaluatorArgs-per-slot.md`,
`fix-closure-capture-type-mismatch.md`, `kernel-mono-closures-implementation.md`.

**Risk:** HIGH — runtime ABI + closure specialization; the only case that fails as a runtime assert.
**Effort:** HARD. Recommend sequencing **after** Fixes 1-5 and treating it as its own milestone.

---

### Fix 7 — Partial-numeric custom types (ResultMap)

**Edge.** Producer = `res = Ok 30 : Result e Int`; the success arg is numeric, the error arg `e` is a
phantom non-numeric var that fails the shape gate.

**Mechanism.** Relax `isNumericFixableShape` to admit a custom type when **at least one** arg is fixable
and the rest are inert. **But:** this is the exact `number`-phantom-inside-a-boxed-custom shape that
produced the `EmbeddedNothing`/`UnboxWrapper` SIGSEGVs during the shipped work. **Gate this fix on an ABI
safety proof:** show (via MLIR + a runtime probe) that re-typing the success arg through `Result`'s boxed
constructor representation does not disturb the error-arg slot. If unsafe, leave `ResultMap` failing and
document it.

**Risk:** HIGH (regression class). **Effort:** moderate code, high validation.

---

## 3. Dependency & sequencing

```
Fix 1 (custom proj)        ─ independent  ─ CustomType, UnionBranch
Fix 2 (control-flow)       ─ independent  ─ IfBranch
Fix 3 (destructor alias)   ─ uses Fix 1's per-slot synth ─ Destructure
Fix 4 (container element)  ─ independent (aligns w/ speckey) ─ ListOfRecords
Fix 5 (builder allowlist)  ─ depends on Fix 4 ─ ArrayMap
Fix 6 (closures)           ─ independent, HARD, own milestone ─ ClosureInRecord, ListOfClosures
Fix 7 (partial customs)    ─ ABI-safety-gated, HIGH risk ─ ResultMap
```

**Recommended order:** 2 → 1 → 3 → 4 → 5, then 6, then 7. Fixes 1-2 are self-contained and the lowest
risk; 3 reuses 1; 4-5 are the container pair; 6 and 7 are the high-risk tail.

Each fix is **independently gated**: it only *widens* `isNumericFixableShape`/`isNumericDataRhs` or adds
a deferral/recording path, so a fix that misbehaves can be reverted without affecting the others — and
the existing zero-regression guarantee must be re-verified after each (the full `elm/` E2E + stress, as
in the shipped plan).

---

## 4. Where the threading lands in the pipeline

All of Fixes 1-5 and the monomorphizer half of Fix 6 are **inside `Specialize.elm`** — they thread a
type that is *already present at monomorphization time* (confirmed by every trace) from a consumer node
onto a producer's `defCanType`/instance. None requires information from a later phase. Two fixes reach
beyond the monomorphizer:
- **Fix 6** additionally needs the codegen capture-ABI (`papCreate` bitmaps, wrapper result kind) and the
  runtime typed evaluator to follow the now-`Float` MonoType — but those are *consumers* of the MonoType,
  not new sources of type information.
- **Fix 1** may need the codegen ctor-field type registry (`Context.elm`) to emit the `f64` slot kind
  (`fix-custom-type-field-type-registration.md`) — again a downstream MonoType consumer.

So the architectural answer holds: the fixes are consumer→producer **data-flow** additions within
monomorphization, plus making two ABI emitters faithfully follow the corrected MonoType.

---

## 5. Test matrix & verification

| Fix | Target tests (FAIL→PASS) |
|---|---|
| 1 | `LetNumberCustomTypeTest`, `LetNumberUnionBranchTest` |
| 2 | `LetNumberIfBranchTest` (+ a new `case`-operand variant) |
| 3 | `LetNumberDestructureTest` |
| 4 | `LetNumberListOfRecordsTest` |
| 4+5 | `LetNumberArrayMapTest` |
| 6 | `LetNumberClosureInRecordTest`, `LetNumberListOfClosuresTest` |
| 7 | `LetNumberResultMapTest` |

**Per-fix verification (mandatory, mirrors the shipped plan):** rebuild guida; run the full `elm/` JIT
E2E (`build/test/test --filter elm/`) — **every pre-existing non-LetNumber test must stay green** (the
zero-regression bar); run the stress suite (`--target stress`). Add a `case`-over-`number` operand test
for Fix 2 and a `let q = p` alias `xfail` note (still out of scope, per the shipped plan §9). Trace
re-runs (`NUMFIRE`/`IFNODE`/`DESTRUCT`/`PENDNUM` via `Debug.log`, per `nul-let-hard-cases.md`) confirm the
threaded type reaches the producer for each fix.

## 6. Confidence

- **High:** Fixes 1, 2 — info is on the node (Fix 1) or one `unifyExtend`/`PendingCall` away (Fix 2);
  both reuse established machinery; both self-contained.
- **Medium:** Fixes 3, 4, 5 — correct threading edges identified, but Fix 3 must reconcile with
  eager-first emission, Fix 4 touches shared container machinery, Fix 5 depends on Fix 4.
- **Lower / sequenced:** Fix 6 (runtime ABI + closure specialization, HARD), Fix 7 (boxed-custom ABI
  regression risk — gate on a safety proof).

Net: Fixes 1-5 should take the LetNumber suite from 29/38 to ~36/38 with zero regressions; Fixes 6-7 are
the harder tail and should be separately milestoned and validated.
