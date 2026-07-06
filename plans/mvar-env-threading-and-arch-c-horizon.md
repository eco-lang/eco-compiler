# MVarEnv Threading (Total Join-R) and the Architecture-C Horizon

## Status: J5 (Option A) IMPLEMENTED & GREEN & BOOTSTRAPS (2026-07-06). Architecture C = horizon, still out of scope.

> **J5 done:** all ~29 taint-capable unify drop sites in `Specialize.elm` now thread the
> returned `MVarEnv` (`setMVarEnv`; fold-accumulator widening; `unifyCallSiteDirect`
> captures the 3rd tuple element; `pushExpectedType`/`refineSubstFromArgExprs` return the
> env and callers thread it). `setMVarEnv` 8→33 sites; zero `Tuple.first (unify…)` remain.
> Join-R is now **total** (structural, not empirical). 12,868 unit + 1,547 E2E + bootstrap
> fixed-point all green.
>
> **Follow-on cleanups landed on top of J5:**
> - **`applySubstPure`** (perf §5.3 + honest type): `applySubst` family renamed and made to
>   return bare `MonoType` (it was verified env-pure — never `freshMVar`/`taintNumber`);
>   dead `(MonoType, MVarEnv)` tuple allocation per `Can.Type` node removed.
> - **Verify-inert deletion loop** (the payoff J5 unblocks — each band-aid disabled, full
>   E2E run, clean signal because Join-R is total):
>   - DELETED (inert, 1547/1547): the `monoTypeContainsFloat` record-only-on-Float guard
>     (now records every number ref) and the `rhsUsesLocalMulti` bailout — plus their
>     now-dead helpers `monoTypeContainsFloat` / `localMultiInstanceCount`.
>   - KEPT (J5-confirmed load-bearing, i.e. a real dependency and NOT a masked Join-R gap):
>     `pushExpectedType` (disabling fails exactly `LetNumberIfBranchTest`) and the
>     `PendingNumberValue` arg-passing path (disabling fails 37 `LetNumber*` tests).
>
> Remaining open: the nextId-threading audit of `buildSchemeInfo`/`refreshSchemeInfo` (P4),
> and the §6.2/§6.3 items. Architecture C unchanged below.

## Why this exists

The quiescence-before-defaulting work (MONO_028) resolves `number` with a **symmetric
constraint join** that has two halves:

- **Join-W (write / router)** — subst-carried. When a number var unifies with a boxed
  `CEcoValue` var, the number becomes the class representative in the *substitution*
  (`unifyMonoMono` :540/:543, `unifyHelp`'s `Can.TVar` arm :394). Because the
  substitution is threaded by *every* caller (nobody drops a `Substitution`), Join-W is
  **robust** — routing/keying is always correct.
- **Join-R (read / healer)** — side-table-carried. Each of those joins also records the
  fact in the shared table via `State.taintNumber` (writes `MVarEnv.superVars`). The
  closing pass and `refreshConstraints` read that table to **heal copies stamped before
  the merge** — a copy stamped `MVar id CEcoValue` whose `id` was later tainted still
  closes to `MInt`.

The problem: `MVarEnv` is threaded through `state.ctx.mvarEnv` in a *manual* style, and
**many call sites discard the returned env via `Tuple.first (TypeSubst.unify … )`**. When a
taint happens inside a dropped-env call, it is lost. So **Join-R is currently *partial*** —
taints persist only at the ~8 sites that already thread the env back (via `setMVarEnv`).

This did not block the session: Join-W keeps routing correct, and the full suite + bootstrap
are green, so the partial Join-R coverage was *empirically* sufficient for the test corpus.
But "empirically sufficient" is a fragile guarantee: a future edit, or an untested destructure/
capture shape, could stamp a pre-merge copy at a dropped-env site and mis-close it (a latent
`i64`/`ptr` boundary bug). **J5 makes Join-R total, converting the guarantee from empirical to
structural**, and clears the last blocker for retiring the remaining verify-inert compensation
machinery with confidence.

## Precise scope (verified against current code, 2026-07-05)

`TypeSubst` functions that return an updated `MVarEnv`:

| Function | Line | Can mutate env? | Why |
|---|---|---|---|
| `unify` / `unifyExtend` / `unifyArgsOnly` | 350 / 358 / 603 | **YES** | reach `unifyMonoMono`/`unifyHelp` → `taintNumber` (J1/J2) |
| `unifyCallSiteDirect(WithExpected)` | 1414 / 1435 | **YES** | same, via `unifyHelp` on supplied args |
| `buildSchemeInfo` / `refreshSchemeInfo` | 1087 / 1123 | **YES (nextId)** | call `buildSchemeRenaming` → `State.freshMVar` (:1192) bumps `nextId` |
| `applySubst` | 760 | **NO** | pure plumbing — no arm calls `freshMVar`/`taintNumber` (audited) |

Drop-site inventory in `Specialize.elm`:

- **~25** `Tuple.first (TypeSubst.{unify,unifyExtend,unifyArgsOnly} …)` — **taint-capable, in scope.**
- **4** `unifyCallSiteDirect(WithExpected)` sites discarding the 3rd (env) tuple element — **taint-capable, in scope.**
- **14** `Tuple.first (TypeSubst.applySubst …)` — **pure; out of scope for correctness** (but a
  perf target: convert to a non-env `applySubstPure`, per `monomorphization-perf-analysis.md` §5.3).
- The `buildSchemeInfo`/`refreshSchemeInfo` sites — **audit separately (nextId, not taints).**

The template already exists: `setMVarEnv : MVarEnv -> MonoState -> MonoState` (:1150) and the ~8
correctly-threaded sites (e.g. :613, :850, :1057).

### The nextId sub-hazard (independent of Join-R)

`freshMVar` bumps `nextId` for scheme instantiation. A **dropped env after a `freshMVar` call
reuses the same fresh id**, aliasing two unrelated instantiation vars. This is a latent
correctness bug orthogonal to taints. The `buildSchemeInfo`/`refreshSchemeInfo` call sites must be
audited to confirm they thread env (most already do — they feed cached-scheme call setup); any that
drop it are a real bug, not just a healing gap.

## Goal / success criteria

1. Every taint-capable unification call site in `Specialize.elm` threads its returned `MVarEnv`
   back into `state.ctx.mvarEnv` (directly via `setMVarEnv`, or through a fold accumulator that
   carries the env). **Zero `Tuple.first (unify…)` / discarded-env `unifyCallSiteDirect` remain.**
2. Every `freshMVar`-allocating call site threads its env (no id reuse).
3. Join-R is demonstrably **total** (see verification), not just empirically sufficient.
4. Full suite (12,868 unit + 1,547 E2E) green and bootstrap fixed-point holds.
5. On the strength of (3), the verify-inert compensation candidates
   (`pushExpectedType`, the `PendingNumberValue` path, `rhsUsesLocalMulti` bailout) can be retired
   in follow-ups without the risk that an unhealed copy is masking a real defect.

## Design: two options

### Option A — targeted site threading (recommended)

Mechanically thread the ~29 taint-capable sites. Two shapes:

- **Straight-line** (`let x = Tuple.first (unify env …)` used once): rewrite to
  `let ( x, env1 ) = unify env …; st1 = setMVarEnv env1 st in …` and use `st1` downstream.
- **Fold accumulator** (the unify is inside a `List.foldl` whose accumulator is subst-only):
  widen the accumulator to `( subst, env )` (or `( subst, state )`), thread the env each iteration,
  and `setMVarEnv` the final env after the fold. These are the fiddly ones (~8–10 of the 29).

Effort: ~29 mechanical edits, ~1/3 needing accumulator widening. Risk: low per site (behavior-
preserving — it only *adds* taint persistence); the danger is *incompleteness*, which the
verification step (a) makes checkable by grep. **This is throwaway-friendly**: Architecture C
deletes the whole `Dict`-substitution engine, so a large structural investment here is not
warranted. Option A is proportionate hardening.

### Option B — structurally couple env into the substitution thread (not recommended now)

Because the `Substitution` is *never* dropped and the `MVarEnv` *should* share its fate, bind them:
thread a `type alias SubstEnv = { subst : Substitution, env : MVarEnv }` everywhere `Substitution`
is threaded. Drops become impossible by construction (you cannot keep the subst and lose the env).
This is the "principled" fix, but it is a pervasive signature change across `TypeSubst` and
`Specialize`, and its entire value is subsumed by Architecture C (which threads a real solver store).
Record it as the ideal end-state; do not build it as a stepping stone.

**Recommendation: Option A**, unless the pre-Arch-C horizon is long enough that Option B's
robustness pays for itself. Decision criterion in "Relationship to other work" below.

## Implementation phases

- **P1 — Classify (no code).** Grep the 39 drop sites; tag each taint-capable (unify family) vs pure
  (applySubst). For each taint-capable site record: straight-line vs fold, and whether `state` (or a
  state alias) is in scope for `setMVarEnv`. Audit `buildSchemeInfo`/`refreshSchemeInfo` sites for
  nextId threading. Output: a checklist (this is the actionable artifact — mirrors the session's
  earlier env-threading audit, re-run against current code).
- **P2 — Thread straight-line sites.** Convert the ~20 non-fold taint-capable sites. Compile after
  each cluster; run the number E2E families (LetNumber/Float/Destruct) + MONO_024/025 as a fast gate.
- **P3 — Thread fold sites.** Widen the ~8–10 fold accumulators. These are the highest-risk edits
  (accumulator identity, order of `setMVarEnv`); test each.
- **P4 — nextId audit fix.** Thread any `freshMVar`-allocating site that drops env.
- **P5 — Demonstrate totality** (see below), then full suite + bootstrap.
- **P6 — (follow-up, separate commits) Retire verify-inert compensation** now that Join-R is total:
  `pushExpectedType`, `PendingNumberValue`, `rhsUsesLocalMulti` bailout — each grep + suite-gated.

## Verification — how to show Join-R is *total*, not just green

Green suites prove "didn't break," not "now total." Three complementary checks:

1. **Static completeness (necessary):** after P2–P4, `grep` proves no `Tuple.first (TypeSubst.unify`
   / `unifyExtend` / `unifyArgsOnly` and no discarded-env `unifyCallSiteDirect` remain in
   `Specialize.elm`. This is the structural guarantee.
2. **Targeted healing witness (sufficient evidence):** add a `runToMono` unit test that constructs
   the pre-merge-stamped-copy shape (a number arg whose type is stamped `CEcoValue` at a site that
   *previously* dropped the env, then tainted by a later join) and assert the closed graph has it as
   `MInt`. This directly exercises the healing path the threading restores.
3. **Bootstrap fixed-point** (regression backstop): self-compile still reproduces byte-for-byte.

## Risks

| Risk | Mitigation |
|---|---|
| Missed a taint-capable site → healing still partial | P1 checklist + static-completeness grep in P5; the whole point is to make this checkable |
| Fold accumulator threaded wrong (env clobbered/stale) | one fold per commit; the env is monotonic (superVars grows, nextId grows) so a "last-writer-wins" merge on the accumulator is safe; test each |
| Over-investing before Arch C makes it moot | Option A only; do NOT build Option B; keep edits mechanical and reversible |
| nextId audit surfaces a real aliasing bug | that is a *win* (latent bug found); fix and add a regression test |

## Architecture C — the horizon that subsumes this

`design_docs/monomorphization/solver-reuse-evaluation.md` (and `design_docs/hm-solver-reuse.md`)
established **Architecture C**: reuse the HM solver as monomorphization's unification engine — a
fresh solver store per work item, loaded from the typed IR's `MVarId → Point`, real `Unify`, and
`zonkToMono` with **defaulting-at-readback**. It is NOT the snapshot+tvar form (that was the deleted
MonoDirect experiment; its post-mortem is in the eval doc and the `plans/*monodirect*.md` set).

**How this session de-risked it — the two gates the eval doc named are now met:**

- **Quiescence-at-readback = zonk-at-readback.** Architecture C's `zonkToMono` defaults numbers at
  readback, exactly once, at the end. This session *implemented that placement inside the existing
  `Dict` engine* (MONO_028: preserve `CNumber` through the fixpoint; discharge once in the fused
  Prune close). So the defaulting *semantics* Arch C needs are already validated end-to-end —
  Arch C changes the *engine*, not the *when*.
- **Constraint-as-data.** Architecture C's store carries supers natively (`FlexSuper`/`RigidSuper`).
  This session replaced the name-prefix channel with real exported supers (`RootedVar.super` +
  `varSupers`, TYPE_SUPER_001) feeding `MVarEnv.superVars`. So the constraint *source* Arch C needs
  is already data, not string prefixes.
- **The join is native.** Join-W/Join-R (number dominates CEcoValue) is a hand-rolled union-find
  merge over a `Dict` substitution + a side table. In a real solver store this is just `unify` on
  two descriptors with a super-lattice `⊔` — no side table, no `refreshConstraints`, no J5.

**What Arch C subsumes (the reason J5 is a stepping stone, not the destination):**

- The entire `Substitution = Dict Int MonoType` + `findRootVar` path-compression + `insertBinding`
  normalization stack → the solver's persistent-array union-find.
- The **backward-demand compensation** the current engine still carries (the deeper root cause named
  in the old-vs-new comparison): the `Pending*` variants, subst enrichment (S1/S2),
  `unifyCallSiteDirect` staging, `applySubstKeepNumber`-era plumbing, value-multi/number-multi
  demand observation, and the `useExprType` double-specialization fallbacks. All of these exist
  because a producer-first `Dict` engine cannot see consumer demand without retrofits; a
  reference-semantic solver store makes demand flow through unification natively, and `zonk` reads
  the settled result — **there is nothing to defer, replay, or thread**.
- `MVarEnv` threading itself (J5) — the store is the always-threaded state.

**Migration sketch (out of near-term scope; for the eval doc / a future plan):** load per-work-item
store from `MVarId → Variable`; replace `applySubst`/`unify*` with `srcTypeToVariable` + `Unify`
(wrapped to catch the graph-poisoning failure mode); replace the closing pass with `zonkToMono`
(defaulting `Number`-super flex vars to `Int` at readback); delete the side-table/Pending/enrichment
machinery. Gate: the structural super export (done) + module-scoped roots (done) + kernel-type
honesty (PostSolve first-usage-wins fabrications) — the last remains the open prerequisite the eval
doc flags.

## Relationship to other work

- **Prerequisite-of / enables:** the verify-inert deletions in the old-vs-new comparison report and
  in `number-quiescence-before-defaulting.md`'s deletion phase (Join-R totality removes the risk that
  those deletions unmask an unhealed copy).
- **Superseded-by:** Architecture C (`solver-reuse-evaluation.md`) — which is *why* Option B (the big
  structural coupling) is not worth building.
- **Adjacent perf:** `monomorphization-perf-analysis.md` §5.3 (the 14 pure `applySubst` drop sites →
  `applySubstPure`) can be swept in the same pass as P1's classification, since both touch the same
  `Tuple.first (applySubst …)` sites.
- **Decision criterion (J5 now vs skip to Arch C):** do J5 (Option A) if the verify-inert deletions
  are wanted in the near term OR Arch C is more than ~one milestone away. If Arch C is the immediate
  next project, skip J5 and let the store subsume it — J5's only durable value is the correctness
  guarantee, which Arch C provides differently.
