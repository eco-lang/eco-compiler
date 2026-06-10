# Plan: Stop dropping the `CNumber` constraint when a number var shares a solver root

**Status:** PROPOSED
**Component:** Compiler — `Compiler.Monomorphize.AssignMVarIds` (MVarId assignment / constraint
side-table). Downstream consumer: the number-multi machinery in `Compiler.Monomorphize.Specialize`
(gated on `CNumber`).
**Fixes:** `elm-oo-style-mul-float-rootcause.md` — `Kernel signature mismatch for
Elm_Kernel_Basics_mul_Float: (f64,f64) vs (f64,i64)`. A `number` is miscompiled to `i64` in a `Float`
multiply because its `CNumber` constraint was silently dropped.
**Related:** `solver-root-backed-mvar-ids.md`, `mvar-id-global-assignment.md`,
`phantom-typed-id-tvar-constraint-sidetable.md`, `freshen-scheme-tvars-global-id-supply.md`.

---

## 1. Root cause (from the traced investigation)

`AssignMVarIds` assigns each type variable an `MVarId` and records, in a side-table
(`GlobalMVarState.numberVars : Set Int`), which ids carry the `CNumber` constraint. The constraint is
derived **purely from the variable's name**:

```elm
constraintFromName name =
    if Name.isNumberType name then Mono.CNumber else Mono.CEcoValue   -- isNumberType = startsWith "number"
```

`ensureMVarIdForRoot` shares one `MVarId` across all type-variable **names backed by the same solver
root** ("two different names backed by the same solver root get the same MVarId"). The constraint is set
**once, from the first name to claim the root**:

```elm
ensureMVarIdForRoot root name ctx =
    case Dict.get rootIdx ctx.state.rootEnv of
        Just mvarId -> ( mvarId, ctx )                                    -- REUSE: new name's constraint ignored
        Nothing     -> freshMVarId (constraintFromName name) ctx.state    -- allocate from the FIRST name only
```

So when a `number`-named variable (`number`, `number1`, …) shares a solver root that was **first claimed
by a non-`number` name** (a generic alias var `a`, an extensible-record row var, etc.), it reuses the
existing `CEcoValue` id and **its `CNumber` constraint is silently discarded**. The traced run of
`elm-oo-style` showed this happening **2942 times** program-wide (`ROOTREUSE-LOSS` probe). For
`Config.config`, `fontSize`'s root lost `CNumber` this way, so `isNumberVar` is `False`, the number-multi
machinery never engages, and `lineHeightRatio * fontSize` emits `mul_Float(f64, i64)`.

The unification itself is sound: if the solver unified a `number` var with a generic var into one root,
that root *is* number-constrained. The bug is that `AssignMVarIds` records the constraint by **first
name**, not by the **join** of all names' constraints.

---

## 2. The fix — `CNumber` dominates on a shared solver root

A solver root's numeric constraint must be the **join** of all its names' constraints, with
`CNumber ⊔ CEcoValue = CNumber` (number is the stronger/narrower constraint, and a shared root is a
single unification variable, so if *any* name for it is number-typed the root is a number). The minimal,
order-independent realization: **upgrade on reuse**.

In `ensureMVarIdForRoot`, change the reuse (`Just mvarId`) branch so that when the incoming `name` is
number-typed but the existing id is not yet in `numberVars`, it inserts the id into `numberVars`:

```elm
ensureMVarIdForRoot root name ctx =
    case Dict.get rootIdx ctx.state.rootEnv of
        Just mvarId ->
            if Name.isNumberType name && not (Set.member (Id.toComparable mvarId) ctx.state.numberVars) then
                ( mvarId
                , { ctx | state = { st | numberVars = Set.insert (Id.toComparable mvarId) st.numberVars } }
                )
            else
                ( mvarId, ctx )

        Nothing ->
            …unchanged…
```

This is symmetric-correct: the *first-`number`-then-generic* order already keeps `CNumber` (reuse never
downgrades), and the new branch fixes the *first-generic-then-`number`* order. After the fix the recorded
constraint is the join regardless of traversal order.

**Mirror the same join in the `ensureMVarId` (name-keyed) path?** No change needed there — that path keys
by *name*, so two distinct names never share an id and there is no first-name-wins hazard. The defect is
specific to root sharing.

**One subtlety to verify during implementation:** `numberVars` is threaded on `GlobalMVarState` (the
`ctx.state`), and `ensureMVarIdForRoot`'s reuse branch currently returns `ctx` unchanged. The upgrade
must thread the updated `state` back (as sketched), and every caller already propagates the returned
`ctx`, so no signature change is required.

---

## 3. Deeper alternative (record for follow-up, not this change)

The fragility is that `AssignMVarIds` *infers* `CNumber` from the variable **name** at all. The solver
already knows which roots are `number`/`comparable`/… constrained. A more robust design threads the
solver's actual per-root constraint (via the `SolverRoots`/`SchemeRoots` tables already consulted in
`rewriteAnnotation`) into `ensureMVarIdForRoot`, so the constraint is read from the solver rather than
guessed from a name. That removes the whole class of name-vs-root mismatches (and any case where a
`number` var is *renamed* to a non-`number` name, which the §2 join does not catch because no
`number`-named occurrence ever exists for that root). It is a larger change touching the
`solver-root-backed-mvar-ids` plumbing; §2 is the targeted fix for the observed defect and should land
first, with this as a documented follow-up.

---

## 4. Risk & blast radius

- **`numberVars` will gain members.** The `ROOTREUSE-LOSS` probe fired 2942× on one project, so the fix
  flips a broad population of vars from `CEcoValue` to `CNumber`. Most were harmless (defaulted to `Int`
  and used at `Int`); the fix now routes them through the number-multi machinery. This is the intended
  correction, but it materially changes which bindings get number-multi instances — so it must be
  validated against the **full E2E + stress + bootstrap** suite, watching for (a) new specializations,
  (b) any `MONO_024`/`CGEN_001` regressions, (c) bootstrap fixpoint divergence.
- **Soundness direction is safe:** the change only *adds* `CNumber` to roots that are genuinely
  number-unified; it never removes a constraint. A wrongly-added `CNumber` is impossible because the id is
  shared only with genuinely-unified number-named occurrences.
- **Performance:** one extra `Set.member`/`Set.insert` per root reuse — negligible.

---

## 5. Test plan

### 5.1 Targeted E2E reproducers (DERIVED AND KEPT — confirmed failing pre-fix)

Five candidate shapes were derived from the principle "unify a `number` against a non-`number`-named
generic var, then use it at `Float`," and each was run on the current (unfixed) compiler. **The trigger
is generic polymorphic *application* — applying a function/constructor whose signature has a generic `a`
to a `number` literal — NOT extensible records.** Four of five reproduce the *identical*
`mul_Float (f64,f64) vs (f64,i64)` crash and are **kept** under `test/elm/src/`; the fifth did not
reproduce and was discarded:

| Test (`test/elm/src/`) | Pattern | Generic source | Result |
|---|---|---|---|
| `NumberRootReuseTuple.elm`  | `n = Tuple.first ( 30, "x" )`           | `Tuple.first : (a,b)->a`        | **reproduces** ✓ |
| `NumberRootReuseMaybe.elm`  | `n = Maybe.withDefault 0 (Just 30)`     | `Maybe.withDefault : a -> Maybe a -> a` | **reproduces** ✓ |
| `NumberRootReuseCustom.elm` | `n = unbox (Box 30)` (`type Box a = Box a`) | user ctor `Box a`           | **reproduces** ✓ |
| `NumberRootReuseList.elm`   | `n = Maybe.withDefault 0 (List.head [ 30 ])` | `List.head : List a -> Maybe a` | **reproduces** ✓ |
| — (`useTag : { r | tag : String }` row) | extensible-record consumption of a `number` field | row var `r` | did NOT reproduce → discarded |

Each kept test computes `round (1.5 * n)` and `CHECK`s `numrootreuse: 45`; on the unfixed compiler it
fails at compile with the kernel mismatch. **These are TDD/regression tests for this plan: they are
expected to FAIL until §2 lands, and to PASS afterward.** (That the extensible-record shape does *not*
reproduce corrects the earlier `Config a`-row hypothesis in `elm-oo-style-mul-float-rootcause.md §5`: the
real trigger is the many generic applications in `config`'s body, e.g. `Array.fromList`,
`Vector2d.unitless`, that share solver roots with `fontSize`'s `number`.)

### 5.2 Integration repro

If a single-/two-module reproducer proves too sensitive to traversal order to be stable, keep a reduced
multi-module fixture mirroring `Config` + `Style.global : Config a` (the proven trigger) under the
package/E2E fixtures, plus the `elm-oo-style` project build itself as an integration check.

### 5.3 Verification

1. **Pre-fix:** confirm each kept reproducer FAILS on the current compiler (crash or wrong value).
2. **Post-fix:** rebuild guida; every kept reproducer passes; `elm-oo-style` (`eco make src/elm/Main.elm`)
   compiles and runs.
3. **Zero-regression bar:** full `elm/` E2E + stress (`--target full`, `--target stress`) all green.
4. **Bootstrap:** `--target bootstrap` reaches the byte-identical md5 fixpoint (the fix is in a
   self-compiled pass, so the compiler recompiles itself through it).
5. Optionally add a **post-solve invariant test** (cf. `post-solve-non-regression-invariants.md`): for
   every solver root shared by ≥2 names, the recorded constraint equals the join of the names'
   `constraintFromName` results — a structural guard against re-introducing first-name-wins.

---

## 6. Confidence

High on the diagnosis (traced to the exact line, `ROOTREUSE-LOSS` confirmed 2942×) and on the fix being
*sound* (only adds `CNumber` to genuinely-number roots). Medium on blast radius — flipping a large
latent population to number-multi is the correct fix but needs the full suite + bootstrap to confirm no
new specialization or fixpoint surprises. The name-based inference remains a latent fragility addressed
fully only by §3.

---

## 7. Implementation results (SHIPPED — and a second mechanism)

**Status: SHIPPED.** Implementing §2 revealed that the `mul_Float (f64,i64)` symptom on `elm-oo-style`
is produced by **two independent mechanisms**, not one. The complete fix is §2 **plus** a number-multi
gate relaxation.

- **Mechanism A — constraint loss (this plan's §2).** `ensureMVarIdForRoot` now joins `CNumber` on root
  reuse. Verified by tracing: `Config.config`'s `fontSize` went from `hasNum=False` to `hasNum=True`
  (the upgrade fired 110× on `elm-oo-style`), and the crash moved off `Config`. §2 is **necessary** —
  `fontSize` stays `CEcoValue` without it, so no downstream gate change can help it.

- **Mechanism B — number-multi gate too conservative (NOT a constraint loss).** With §2 applied the
  crash moved to `Pointer.scaleWheel`'s `modeMultiplier = case deltaMode of … -> 40/800/1`, which is
  `hasNum=True` (constraint intact) but `dataRhs=False`: the `isNumericDataRhs` provenance gate rejects a
  `case`/`if`/generic-function-call RHS, so the scalar `number` defaults to `Int` and miscompiles at
  `Float`. **The five derived reproducers in §5.1 are all Mechanism B** (`hasNum=True`,
  `Tuple.first`/`Maybe.withDefault`/`Box`/`List.head` RHS) — not Mechanism A.

  Fix: widen the number-`Let` gate with `isScalarNumberShape` — a bare `MInt`/`MFloat` binding may enter
  the number specialization even on a non-data RHS. **Crucially, this is additionally gated on a real
  Float demand** (`demandedNumericUseType defName body … /= Nothing`). The first attempt (scalar shape
  alone) reintroduced the boxed-custom SIGSEGV class (`EmbeddedNothingInCustomTypeTest`,
  `UnboxWrapperNothingTest`, +4) because a scalar `number` can still flow into a *boxed* field; requiring
  a concrete Float use restricts the widening to exactly the Int-vs-Float-default case and leaves
  boxed-only scalars on the eager path. With the demand gate: zero regressions.

**Files:** `AssignMVarIds.ensureMVarIdForRoot` (§2 join); `Specialize.isScalarNumberShape` + the
number-`Let` gate (Mechanism B), reusing the existing `demandedNumericUseType` scan.

**Verification:** full E2E **1475/1475** (zero regressions — includes the 5 reproducers now passing and
the 6 transiently-regressed tests restored), stress **100/100**, and `elm-oo-style` compiles
whole-program with no `mul_Float` mismatch. Bootstrap fixpoint + native binary build per §5.3.

**Follow-up still open:** §3 (solver-constraint-backed naming) would make Mechanism A robust against any
generic-renaming with no number-named occurrence to upgrade from; and the Mechanism-B gate could be
generalised beyond scalars (to numeric containers) if a future case needs it, under the same Float-demand
guard.
