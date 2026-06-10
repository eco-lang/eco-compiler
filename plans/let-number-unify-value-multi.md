# Plan: Unify `let`-number specialization into the general value-multi machinery

**Status:** PROPOSED (design grounded in a three-track code investigation; no spike required — the reused
machinery already exists and is exercised by the shipped lambda-value path)
**Component:** Compiler — monomorphizer (`Compiler.Monomorphize.Specialize`), plus one downstream
ABI-*consumer* validation in codegen + the runtime typed evaluator (no new monomorphizer mechanism).
**Supersedes:** Fix 3 and Fix 6 of `let-number-consumer-producer-threading.md`. Those propose
number-specific apparatus (a new `numberProjAliases` table; a bespoke closure-spec path). This plan shows
the apparatus already exists as the general value-multi machinery and reframes both fixes as *reuse +
one symmetric addition*, which is materially less code and removes the brittleness.
**Builds on:** `value-multi-specialization.md` (PATH 2, shipped), `let-number-demand-driven-specialization.md`
(PATH 3, shipped), `nul-let-hard-cases.md` (trace evidence), `closure-constraint-propagation.md` (shipped).

---

## 1. The reframe (thesis)

The `TOpt.Let` handler in `Specialize.elm` has two demand-driven multi-instance branches that write into
the **same** `ValueMultiState` / `ValueInstanceInfo` structures (`State.elm:297-319`), use the **same**
instance key (`Mono.toComparableMonoType`), and the **same** allocator (`getOrCreateValueInstance` /
`updateValueMultiStack`, `1106-1210`):

- **PATH 2 — lambda-carrying value-multi** (`Specialize.elm:3006-3188`). Gate
  `shouldUseValueMulti = typeContainsLambda && hasCEcoTVar` (`417-419`). Handles a let-bound *value*
  whose type embeds a closure (getter/setter, record-of-closures).
- **PATH 3 — number-multi** (`Specialize.elm:3194-3357`). Gate
  `hasUnresolvedNumberVar && isNumericFixableShape && isNumericDataRhs` (`3194`). Handles a let-bound
  *value* carrying an unresolved `number`.

**PATH 3 is a feature-dropped fork of PATH 2.** It reuses PATH 2's recording, keying, allocator, and
per-instance re-specialization, but omits exactly two of PATH 2's mechanisms — and those two omissions
are precisely the two deferred failures:

| Deferred failure | The PATH-2 mechanism PATH 3 dropped |
|---|---|
| **Fix 3 — destructure of a number** (`LetNumberDestructureTest`) | the destructor-refinement triad + its **second-hop feedback** (`derivedDestructorNames` → `refineValueMultiForDestructorCall`) |
| **Fix 6 — number captured by a closure-in-container** (`LetNumberClosureInRecordTest`, `LetNumberListOfClosuresTest`) | use-site routing into PATH 2's `specializeLambda` constraint propagation + capture typing |

Both dropped mechanisms are **type-agnostic** in the existing code. The number case needs the *same
patterns, interpreted differently* along two axes (§3). So the solution shape is **"merge number into the
value-multi machinery,"** not "build new number-specific tables."

A telling corroboration: `value-multi-specialization.md` consciously punted on this exact case —
> *"Destruct bindings (Q3): Not included. Destructors get concrete types from pattern matching context."*

That premise holds for a **boxed** closure leaf (its concrete type *is* fixed by the pattern), but is
**false for a number leaf**: a destructured `number`'s Int-vs-Float resolution is *not* on the
destructor — it is two hops away, on the *uses* of the bound variable. This plan revisits Q3 specifically
for the numeric leaf.

---

## 2. The shared shape both paths already use

General `a` / closure specialization is a five-step skeleton. PATH 3 implements steps 1, 2, 5 and **drops
3, 4**:

| # | Step | Mechanism (file:line) | PATH 2 | PATH 3 |
|---|---|---|---|---|
| 1 | one binding → N instances, keyed by demanded monoType | `getOrCreateValueInstance` / `updateValueMultiStack` `1106-1210`; key `Mono.toComparableMonoType` | ✅ | ✅ |
| 2 | per-instance RHS re-specialization | `unifyExtend defCanType …` → `specializeDef` → `renameMonoDef` (PATH 2 `3122-3145`; PATH 3 `3305-3322`) | ✅ | ✅ |
| 3 | projection refinement at destructure | `getValueMultiRootFromPath` `814-831` → `buildPartialContainer` `947-1055` → `getOrCreateValueInstance` → `rewriteRootInPath` `851-880` (Destruct handler `3433-3515`) | ✅ | ⚠️ runs but no-ops |
| 4 | second-hop feedback (a *use* of a projected local refines its instance's `info.subst`) | `tagValueInstanceWithDestructor` `1222-1259` (writes `derivedDestructorNames`) → `findInstanceByDestructor` `1318-1332` → `refineValueMultiForDestructorCall` `1274-1311` (called `2587-2597`) | ✅ | ❌ absent |
| 5 | ABI follows the resolved monoType | `monoTypeToAbi` `Types.elm:159-177`; `mlirTypeToKind` `336-349` | ✅ | ✅ |

**The one critical divergence inside step 2.** PATH 2 re-derives each instance's emit type from the
*refined* `info.subst`:
```elm
-- Specialize.elm:3126-3137 (PATH 2)
instanceDefMonoType0 = Mono.forceCNumberToInt (applySubstFV stateAfterBody info.subst defCanType)
mergedSubst = unifyExtend defCanType instanceDefMonoType0 info.subst
```
PATH 3 re-derives from the *static* recording-time `info.monoType`:
```elm
-- Specialize.elm:3309-3311 (PATH 3)
mergedSubst = unifyExtend defCanType info.monoType info.subst
```
So even where PATH 3's instances *do* accumulate a refined subst, the emit loop ignores it. Adopting
PATH 2's "emit from refined `info.subst`" line is a precondition for steps 3–4 to have any effect on the
number case.

---

## 3. The two reinterpretation axes (+ the one retained constraint)

The number case needs the same shape with two reinterpretations and one number-only invariant kept:

1. **Leaf representation.** PATH 2's projected leaf is `MFunction` (a *boxed* getter/setter); the number
   leaf is `MFloat` vs `MInt` (an *unboxed* scalar). `buildPartialContainer`, `unifyExtend`,
   `getOrCreateValueInstance`, and `rewriteRootInPath` are all already type-agnostic — letting the slot be
   `MFloat` instead of `MFunction` needs **no change** to any of them. The only obstruction is that
   `applySubstFV` defaults an unresolved `CNumber→MInt` at the destructor node, so the leaf must be lifted
   from a Float *demand site* (axis 2), not read off the destructor.

2. **Second-hop consumer kind.** PATH 2's second hop is a **call** (`get x`), refined by
   `refineValueMultiForDestructorCall` via `unifyArgsOnly`. The number second hop is a **use**
   (`a * 1.5`), where the operator's `Float` paramType resolves the leaf. We add the number twin: a
   use-site refiner that finds the owning instance (the same `findInstanceByDestructor` /
   `derivedDestructorNames` link PATH 2 populates) and unifies the use's resolved `Float` against the
   *projected slot* of the root.

3. **Retained number-only invariant: eager-first emission for `localMulti` order-safety.** A number
   always has a valid default (`Int`), and its RHS can drive `localMulti` recording whose *order* is
   scrambled if the whole RHS is deferred (PATH 2's model). PATH 3 therefore emits the Int instance
   eagerly (`3206-3207`) and *adds* Float copies, guarded by `rhsUsesLocalMulti` /
   `localMultiInstanceCount` (`3222-3225`) and seeded with an explicit Int instance (`3258-3269`). This
   guard **stays**. The resolution (§4) is to route only the *order-safe* RHS shapes (literal
   tuple/record/list/ctor; lambda-in-value) through deferred emission, gated on `localMultiInstanceCount
   == 0`.

---

## 4. Fix 3 — destructure, as reuse (not a new table)

**Today.** `let (a,b) = (30,40) in a*1.5 + b*1.5` takes PATH 3. It emits `_v0 = (i64,i64)` *eagerly*
(`3206`) and seeds the value-multi stack with the Int instance (`3258-3269`). The shared Destruct handler
*does* run `maybeValueMultiRefinement` and `getValueMultiRootFromPath` *does* return `("_v0", …)`
(`3433-3515`), but the projected leaf collapses to `MInt`: there is no Float demand at the destructor
node, and `applySubstFV` defaults `CNumber→MInt`. The Float is two hops away, on `a*1.5` / `b*1.5`. So
the refinement fires as a no-op that merely reproduces the eager `(i64,i64)` seed.

**The deferred plan's `numberProjAliases` table reinvents existing machinery.** `getValueMultiRootFromPath`
already yields `(_v0, path)`; `buildPartialContainer (alias path) leaf` → `unifyExtend` against `_v0`'s
`defCanType` → `getOrCreateValueInstance` already materialises `(Float,Int)` / `(Int,Float)`;
`rewriteRootInPath` already re-points the Destruct to the right copy. None of it is number-specific. **Drop
the proposed table.**

**Changes (all in `Specialize.elm`):**

1. **Route literal-data number RHS through deferred (PATH-2-style) emission**, not eager-first, **gated on
   `localMultiInstanceCount (rhs) == 0`** (the existing delta gate). A tuple/record/list/ctor literal of
   numbers has no `localMulti` to scramble, so deferral is order-safe and lets the Destruct refinement +
   use-site recording run *before* `_v0` is emitted. Keep eager-first for every other number RHS.
2. **Reuse the destructor-refinement triad unchanged** (`getValueMultiRootFromPath` + `buildPartialContainer`
   + `getOrCreateValueInstance` + `rewriteRootInPath` + `tagValueInstanceWithDestructor`). It already tags
   each destructor-bound local (`a`, `b`) onto its source instance via `derivedDestructorNames`.
3. **Add the use-site second-hop refiner** — the number twin of `refineValueMultiForDestructorCall`. At a
   `VarLocal a` use (`2124`) where `a` is a destructor-bound local of a *number* value-multi root (looked
   up via `findInstanceByDestructor a`, reusing the existing `derivedDestructorNames` tag — **no new side
   table**), resolve the use's monotype; if it bears `Float` (`monoTypeContainsFloat`), lift it to the
   root via `buildPartialContainer (alias path) MFloat`, `unifyExtend` against `_v0`'s `defCanType`, and
   `getOrCreateValueInstance` a fresh `(Float,…)` root instance; `rewriteRootInPath` the reads of `a`.
4. **Emit from the refined `info.subst`** (adopt PATH 2's `3126` line in the number emit loop, replacing
   the static `info.monoType` at `3311`), so the `(Float,Int)` / `(Int,Float)` instances actually
   materialise.

Net: one routing change, one symmetric refiner, one emit-loop line. No new data structures.

---

## 5. Fix 6 — closures, as a gate widening (the monomorphizer half already exists)

**Already implemented, general, reusable** (confirmed in code, not just design):

- **Use-site lambda constraint propagation.** `specializeLambda` (`1365-1470`) already reconstructs the
  use-site type and pushes it onto the lambda's params/captures/body:
  ```elm
  -- Specialize.elm:1379-1389
  monoType0  = forceCNumberToInt (applySubstFV state subst canType)
  refinedSubst = unifyExtend canType monoType0 subst   -- drives params (1406-1412) + body (1438-1439)
  ```
  (This is the shipped `closure-constraint-propagation` mechanism — general, not number-specific.)
- **Capture typing follows the substitution for free.** `computeClosureCaptures` (`Closure.elm:144-192`)
  reads each capture's type out of the *already-specialized* body (`165-178`), after the body was
  specialized under `refinedSubst`. So a captured `n` resolved to `Float` inside the body is captured as
  `Float` with no extra mechanism.
- **In-body number resolution** already records `n`'s Float instance via
  `resolveNumberMultiVarRef` / `recordNumberInstanceAgainstShape` (`702-735`) once `x : Float` makes
  `x * n` demand Float.
- **The ABI flip is already type-driven at the creation emitter.** `papCreate`'s `unboxed_bitmap` /
  `_operand_types` come from the captures' actual SSA types (`Expr.elm:1003-1011`), and `_result_kind` is
  `mlirTypeToKind (monoTypeToAbi (typeOf body))` (`1102-1110`). An `MFloat` capture/result yields kind 2
  / `PK_Float` with **no new logic**.

**The only genuinely-new monomorphizer work is the gate.** A record/list holding `\x -> x*n` currently
enters *neither* path: `shouldUseValueMulti`'s `hasCEcoTVar` is explicitly `not isNumberVar` (`401-411`),
and `isNumericFixableShape` has no `MFunction` case (`445-475`). So the closure freezes at `Int->Int` on
the eager path.

**Change:** widen the routing so a value whose type embeds *both* a lambda *and* an unresolved number var
enters PATH 2's use-site specialization (preferred: relax `shouldUseValueMulti` to admit the
lambda+number case, rather than teaching `isNumericFixableShape` about `MFunction` — this puts
number-bearing closures on the *same* PATH 2 that already specializes closures-in-values, which is the
unification thesis). Keep the `rhsUsesLocalMulti` / `localMultiInstanceCount` order-safety guard (§3.3).

**Then validate the downstream consumer (not a new mechanism, but must be confirmed):** that the runtime
typed-evaluator *dispatch* and `papExtend` `_result_kind` *consumption* honour `PK_Float` for the
now-Float closure. The assert at `RuntimeExports.cpp:2003` ("PK_Int evaluator with non-Int/Boxed
desired_kind") is the current symptom; `desiredKind` derivation is `EcoToLLVMClosures.cpp:1607-1631`.
Cross-check `type-aware-buildEvaluatorArgs-per-slot.md` and `typed-papextend-evaluator-return-type.md`.

---

## 6. Reuse-vs-new ledger

| Concern | Reused as-is (general machinery) | Genuinely new |
|---|---|---|
| Instance table / key / allocator | `ValueMultiState`, `toComparableMonoType`, `getOrCreateValueInstance` | — |
| Destructure projection (Fix 3) | `getValueMultiRootFromPath`, `buildPartialContainer`, `rewriteRootInPath`, `tagValueInstanceWithDestructor` | — (replaces proposed `numberProjAliases`) |
| Second-hop feedback (Fix 3) | `findInstanceByDestructor` + `derivedDestructorNames` link | a **use**-site refiner mirroring `refineValueMultiForDestructorCall` (a *call*-site refiner) |
| Emit type from refined subst | PATH 2's `applySubstFV … info.subst defCanType` (`3126`) | one-line swap in the number emit loop (`3311`) |
| Closure use-site spec (Fix 6) | `specializeLambda` `unifyExtend`; `computeClosureCaptures` | — |
| Number capture resolution (Fix 6) | `resolveNumberMultiVarRef` / `recordNumberInstanceAgainstShape` | — |
| Closure ABI emission (Fix 6) | `monoTypeToAbi` / `mlirTypeToKind` / `papCreate` (type-driven) | — (validate consumption only) |
| Routing into the machinery | — | gate widening (Fix 6); deferred-emission routing for literal number RHS (Fix 3), both behind the existing `localMultiInstanceCount == 0` guard |
| `localMulti` order-safety | `rhsUsesLocalMulti` / `localMultiInstanceCount` / Int-seed | — (retained verbatim) |

No new data structures. The new code is: one use-site refiner, two routing/gate widenings, one emit-loop
line, plus a runtime-dispatch validation for Fix 6.

---

## 7. Sequencing

```
Step A  Emit-from-refined-subst (adopt PATH 2's 3126 in the number emit loop)   ── prerequisite for 3,4
Step B  Fix 3: deferred routing for literal number RHS (gate localMultiInstanceCount==0)
Step C  Fix 3: use-site second-hop refiner (twin of refineValueMultiForDestructorCall)
Step D  Fix 6: widen shouldUseValueMulti to admit lambda+number; route record/list-of-closures to PATH 2
Step E  Fix 6: validate runtime typed-evaluator / papExtend consume PK_Float (assert @ RuntimeExports:2003)
```

**Order:** A → B → C (Fix 3, self-contained, low-medium risk), then D → E (Fix 6, the runtime tail).
A is shared and must land first. Each step only *widens* a gate or *adds* a recording/refinement path, so
each is independently revertible, and the **zero-regression bar is re-verified after each** (full `elm/`
E2E + stress, per the shipped plans).

---

## 8. Test matrix & verification

| Step | Target (FAIL→PASS) |
|---|---|
| A | no behaviour change alone; regression-neutral (re-run full `elm/`) |
| B+C | `LetNumberDestructureTest` |
| D+E | `LetNumberClosureInRecordTest`, `LetNumberListOfClosuresTest` |

**Per-step (mandatory, mirrors the shipped plan).** Rebuild guida (`cmake --build build --target guida`);
`touch test/elm/src/*.elm` to bust the MLIR cache; run the full JIT E2E
(`build/test/test --filter elm/`) — **every pre-existing non-LetNumber test stays green** (the
zero-regression bar); run stress (`--target stress`). For Fix 6, additionally run the full bootstrap
(`--target bootstrap`) and confirm the md5 self-compilation fixpoint, because it touches the runtime ABI
path. Trace re-runs (`NUMFIRE` / `DESTRUCT` / `PENDNUM` via `Debug.log`, per `nul-let-hard-cases.md`)
confirm the refined `MFloat` slot reaches `_v0` (Fix 3) and the `PK_Float` capture/result reaches the
emitted closure (Fix 6).

---

## 9. Risk & confidence

- **Fix 3 (Steps A–C): medium, confidence medium-high.** The machinery exists and is type-agnostic; the
  reuse is mechanical. The one real subtlety is the eager-first ↔ deferred routing for literal number
  tuples (§3.3); the `localMultiInstanceCount == 0` gate keeps it tight. The use-site refiner is a direct
  structural mirror of the shipped call-site refiner.
- **Fix 6 (Steps D–E): higher, confidence medium.** The monomorphizer half is already general and
  present, so the *new* monomorphizer surface is just the gate. Risk concentrates in Step E — the runtime
  typed-evaluator dispatch must honour `PK_Float` end-to-end; the creation emitter already does, but the
  consumption side (papExtend `_result_kind`, `invokeSaturatedTyped`) must be validated, and the gate
  widening could pull additional closure-in-value shapes into deferral (re-verify zero regressions +
  bootstrap).

**Net:** A–C should close `LetNumberDestructureTest`; D–E close the two closure tests, taking the
LetNumber suite to 38/38. The work is predominantly *deletion of the proposed bespoke apparatus* in favour
of reusing PATH 2, which both shrinks the change and removes the brittleness the standalone Fix 3/Fix 6
designs carried.

---

## 10. Relationship to existing plans

- **Supersedes** `let-number-consumer-producer-threading.md` §Fix 3 (the `numberProjAliases` table is
  unnecessary — §4) and §Fix 6 (the closure-spec path already exists — §5). The other fixes in that plan
  (1, 2, 4, 5, 7) shipped and are unaffected.
- **Revisits** `value-multi-specialization.md` Q3 ("Destruct bindings — not included") for the numeric
  leaf only: the premise "destructors get concrete types from pattern matching context" is false for a
  `number` leaf (the type is on the *uses*, two hops away), which is the entire reason Fix 3 exists.
- **Reuses, does not modify** `closure-constraint-propagation.md` (already shipped `specializeLambda`),
  `type-aware-buildEvaluatorArgs-per-slot.md`, and `typed-papextend-evaluator-return-type.md` (the Fix 6
  consumption-side validation references these).

---

## 11. Implementation results (SHIPPED)

**Status: SHIPPED.** Both deferred failures are fixed; `LetNumber` suite is now complete. Verified: full
E2E **1471/1471**, stress **100/100**, bootstrap fixpoint **byte-identical** (`eco-compiler-boot.mlir` ==
`eco-compiler-boot-2.mlir`, md5 `907b5c6bb57657fde2f870bdc56b0135`). Zero regressions. All changes are in
`Compiler.Monomorphize.Specialize`; no runtime/codegen change was needed.

What landed, and where it diverged from the plan:

- **Step A (as planned).** The PATH 3 number float-emit loop now re-derives each instance's type from the
  refined `info.subst` (`Mono.forceCNumberToInt (applySubstFV stateAfterBody info.subst defCanType)`),
  mirroring PATH 2's D6 loop, in both the def fold and the varEnv fold.

- **Fix 3 — Steps B + C collapsed into one mechanism (better than planned).** A Phase-0 trace (kept here
  as the key finding) showed the deferred-routing premise was wrong: a destructor-bound `number`'s use
  node does **not** carry the resolved `Float`. It carries a fresh, *unresolved* per-use instantiation
  var (e.g. `TVar 614`) that `applySubstFV` defaults to `MInt` at Destruct-processing time — the `Float`
  only enters `subst` later, when the enclosing `*` call's unification propagates the sibling `1.5`
  through `number→number→number`. So neither deferred routing nor reading `meta.tipe` suffices.

  The shipped fix is a **call-context demand scan** at the destructor: `demandedNumericUseType` /
  `collectNumericDemands` / `callArgDemands` walk the body, and at each call in which the bound variable
  is a direct argument, *replay the call-site unification* (`applySubstKeepNumber` to keep `number` vars
  un-defaulted, then `unifyArgsOnly` against the callee's `TOpt.typeOf`) and read the refined type at the
  variable's position. The first use that resolves to a Float-bearing type becomes the destructor's slot
  type, so `buildPartialContainer` → root instance → emitted destructor all materialise at `Float`. This
  is the number twin of the closure case's `refineValueMultiForDestructorCall` (a *use* drives it, not a
  *call* of the bound value), realised without the proposed `numberProjAliases` table and without
  deferred routing — eager-first emission is retained. General: it unifies against *any* callee's type,
  with no name/arity special-casing. (`LetNumberDestructureTest` → pass; MLIR shows `mul_Float`/`f64`.)

- **Fix 6 — Step D only; Step E unnecessary.** Widening the gate to
  `typeContainsLambda && (hasCEcoTVar || hasUnresolvedNumberVar)` was sufficient. The Call handler's
  non-local fallback already specializes the callee (`rec.f`, a list element) via
  `specializeExpr func callSubst`, where `callSubst` binds `number→Float` from `unifyCallSiteDirect`
  against the applied arg — so once `rec`/`fns` enter PATH 2, the `Access` (number-multi) handler records
  the `{ f : Float -> Float }` instance, PATH 2 re-specializes the closure at `Float -> Float`,
  `specializeLambda` + `computeClosureCaptures` carry `n : Float` into the capture, and the emitter
  produces `f64`/`PK_Float` by `monoTypeToAbi`. **No runtime change**: the `RuntimeExports.cpp:2003`
  assert only fired for an `Int`-frozen evaluator meeting a `Float` demand; here the evaluator is
  genuinely `PK_Float`, so the kinds match. (`LetNumberClosureInRecordTest`,
  `LetNumberListOfClosuresTest` → pass; MLIR shows `float.mul`/`float.add` + `_result_kind`.)

Known cosmetic non-issue: for a destructured tuple whose siblings are all used at `Float`, each
destructor materialises its own per-slot root instance (`(MFloat, ·)` and `(·, MFloat)` with a boxed/Int
filler at the untouched slot) on top of the dead eager `(i64,i64)` — correct but allocates the literal
tuple more than once. The redundant instances are dead and pruned downstream; collapsing them into one
`(MFloat, MFloat)` instance is a possible future optimization, not a correctness concern.
