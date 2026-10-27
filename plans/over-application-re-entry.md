---
status: not-started
updated: 2026-10-27
---

# Plan: Over-Application Re-Entry in the Generic Apply Path

**Status: NOT STARTED.** Step 0 is a census and must run first. It decides whether Steps 1 and 2
are built at all.

## 1. The idea, as first recorded

The 2026-09-08 direct-call decline census ranked this as the best remaining target for generic
dispatch. The census is preserved in the appendix. Its entry read:

> **Over-application re-entry**, 92.0 M (9.9 %). The compiler already knows statically which sites
> over-apply: that IS `arityOver`, and LSS_039 peels the type there. Emitting the saturating call
> plus the residual application as two ops, instead of routing both through the runtime, removes
> one dispatch per over-applied call. A codegen change, not a rewrite. **Unexamined.**

`plans/io-monad-caller-direct-state.md` §8 and `plans/lss-inline-member-propagation.md` §8 both
defer to it as the cheaper move to make first.

## 2. What the runtime does today

`eco_apply_closure_eval` (`runtime/src/allocator/RuntimeExports.cpp`, the "Over-saturated" branch)
handles `num_args > remaining` like this:

1. It records a `Generic` dispatch.
2. It calls `eco_closure_call_saturated` with the first `remaining` arguments. Stage 1's
   evaluator runs and returns a closure, the *intermediate*.
3. It builds a sub-`EvalParamLayout` for the trailing arguments, on the stack, or on the heap past
   64 of them.
4. It calls itself recursively on the intermediate. The recursion pushes roots again and reads the
   header again, then takes the exact, under or over branch.

The census probe counted 91,978,380 entries to `eco_apply_closure_eval` from
`eco_apply_closure_eval+0x820`, which is step 4. A further 15,982,344 came from
`eco_apply_closure_typed+0x14`, the same shape one level up.

## 3. Re-examining the idea: it does not remove a dispatch as worded

Three facts, each checked against the code on 2026-10-27:

1. **The split already exists where the compiler can prove it.** LSS_014 (E2.7 staged stamp)
   stamps an over-applying site whose callee is a singleton lambda set with a matching first
   stage. `Expr.generateStagedFastDispatchCall` then emits exactly what the census proposes: a fast
   `papExtend` that saturates stage 1, then one generic `papExtend` for the residual
   (`applySegUnknownToVar`). The `CallGenericApply` arm of `generateCall` tries it before falling
   back to `generateGenericApplyCoerced`. LSS_039 (the flat peel) then took `arityOver` from
   12,382 sites to 379.
2. **The sites still re-entering are ones the compiler cannot split.** A plain generic `papExtend`
   reaches the runtime's over-saturated branch only when the runtime closure's remaining arity is
   below the argument count. LSS_039 records why the call site's type cannot tell us that: an
   arrow type is representation-agnostic. A flat closure, a curried chain and a PAP all inhabit it.
   Only an instance, a stamp, licenses a split, and stamped sites are already split. `arityOver`
   (379 sites) is a static *decline* reason. It is not the population that re-enters at runtime,
   and the census conflated the two.
3. **A blind split moves the dispatch instead of removing it.** Suppose codegen emitted two generic
   `papExtend`s, k arguments and then the rest. The runtime would still run stage 1's evaluator,
   then dispatch the intermediate through the generic funnel. The second event would just be
   attributed to the Elm site instead of `eco_apply_closure_eval+0x820`. It saves no evaluator
   call and no allocation. It is also unsound when k is not every member's stage arity.

A syntactic curried lambda (`\a -> \b -> ...`) is already one flat closure after mono. So a closure
that really stages at runtime returns a *computed* closure from stage 1, such as an IO continuation
`\a -> someIO`, where an IO value is a function. Two indirect calls are then inherent. Only
inlining or a different representation removes one. That is the IO-monad arc's ground
(`plans/io-monad-dispatch-reduction.md`, `plans/io-monad-caller-direct-state.md`). It is also
consistent with `inline.partialHof` removing 43.5 M of these re-entries, about 40 %, by inlining
`IO.andThen`, not by any codegen split (`benchmarks/lss-opt.md`).

**What is left that is real:**

- **(a) Attribution.** Which source sites produce the re-entries, and why their callee stages.
- **(b) Overhead.** The re-entry pays a function call, a second root push, a sub-layout copy and a
  second header decode. It does not have to.
- **(c) A narrow static split.** A stamp-less site where *every* member of the callee's lambda set
  has the same first-stage arity k < argCount, and stage 1 of every member returns a lambda set
  that is itself a singleton. The residual could then be stamped fast. This is a generalisation of
  LSS_014 from "singleton callee" to "uniform stage, singleton intermediate". It is speculative
  until (a) shows that population has weight.

## 4. Upper bound on the win

The wall model in `benchmarks/lss-opt.md` is 47.7 ns per dispatch. At that rate, removing all 92 M
re-entries outright is worth about 4.4 s of about 468 s, roughly 0.9 %. That is under the file's
3 % bar for a measurable wall change. Option (b) removes overhead, not dispatches, so it is worth a
fraction of that. `inline.partialHof` is the precedent: it removed 83.9 M dispatches and measured
FLAT on wall.

These numbers are from 2026-09. The inliner, η-expansion, the dead-spec prune and alias forwarding
have all landed since, so the re-entry count today is unknown. Hence Step 0.

## 5. Steps

### Step 0: census (decides everything else)

On a current fixed-point self-compile with shipping defaults:

- Count over-saturated entries to `eco_apply_closure_eval`. This is a new `DispatchStats` field,
  `over`, recorded in the over-saturated branch next to the existing `Generic` record and keyed by
  the stage-1 evaluator. It goes with the existing dispatch-stats dump, so `call-stats-extract.py`
  symbolizes it with no bpftrace needed.
- Attribute each to its outer caller and to the stage-1 evaluator. That evaluator's symbol names
  the lambda that stages.
- Classify the top evaluators:
  - IO continuation (`\a -> io`).
  - A computed closure from another HOF.
  - A uniform-stage lambda set (candidate for (c)).
  - Kernel-originated (`eco_apply_closure_typed` from C++).
- Record it as a new run in `benchmarks/call-stats.md`.

**Go/no-go.**
- Under about 3 % of generic dispatch: close the plan as measured out.
- Mostly IO continuations: hand the number to the IO-monad arc and close this plan.
- Otherwise, take Step 1, and take Step 2 only if (c)'s population carries weight.

### Step 1: cheapen the runtime re-entry (option (b))

This is a runtime-only change, with no compiler or MLIR change:

- Turn the recursion into a loop inside `eco_apply_closure_eval`. Advance `typed_args` and
  `args_layout->kinds` by an offset instead of copying a sub-layout. The kinds stay in the original
  layout, and the loop carries `(kinds_base, offset, count)`.
- Root the intermediate in the slot already pushed for `closure_bits`. Overwrite it instead of
  opening a new root range. The trailing argument slots were rooted on entry and stay rooted.
- Keep the per-stage `dispatchStatsRecord` calls, so `gen` and `sat` counts stay bit-identical.
  That is the correctness gate for the counters.

Invariants to re-read first: the HEAP_* rooting rules (the intermediate is a fresh allocation and
the next stage's evaluator can GC), CGEN_052 and CGEN_056 (`remaining_arity` absent means generic),
and the result-kind cross-check, which today reads the intermediate's `result_kind` into the
sub-layout.

### Step 2: uniform-stage split (option (c)). Only if Step 0 shows the population

- AbiCloning gets a new resolution, next to LSS_014's staged stamp. It applies when the callee
  set's members are all non-PAP instances with identical first-stage param ABI k < argCount, and
  every member's stage-1 return set is the same singleton.
- Emission: a generic exact `papExtend` of k arguments (`remaining_arity = k` is truthful by
  the uniform-stage proof), then a *fast* stamped call on the singleton intermediate. This removes
  the second dispatch, unlike a blind split.
- It needs a new invariant row (LSS_0xx), with the uniformity and singleton-return conditions as
  load-bearing as LSS_014's, and a pinned negative test: a set with mixed stage arities must not
  split.

## 6. Gates

- Step 0: the census run reproduces the existing `gen` and `sat` totals to the count with the new
  field added.
- Step 1:
  - Dispatch counters bit-identical to before the change.
  - Unit tests that drive over-saturation at depth: three or more stages, more than 64 trailing
    arguments, and a primitive `desired_kind` on the last stage.
  - GC-pressure stress, and the `build-validate` (ECO_HEAP_VALIDATE) unit and E2E suites.
  - `--target full` once, a bootstrap (4b, 8c and 9b), and wall per the `benchmarks/lss-opt.md`
    protocol.
- Step 2: as Step 1, plus a flag-off byte-identity rail, a bootstrap fixed point with the flag on,
  elm-tests, and a `call-stats.md` run showing `gen` down by the predicted amount.

## 7. What NOT to do

- **Do not split on the call site's arrow type.** It is representation-agnostic (LSS_039). A split
  at k when the closure's stage arity is not k reaches the evaluator with the wrong argument count.
- **Do not count a moved dispatch as a removed one.** A generic `papExtend` on the intermediate is
  the same dispatch the runtime made. Judge on `gen` plus `sat` per source call, and on wall.
- **Do not change `eco_closure_call_saturated`'s boxed-intermediate contract** in Step 1. The
  under-saturated path and C++ kernel callers rely on it.

## Appendix: the 2026-09-08 direct-call decline census

Kept here when `/work/direct-call-decline-census.md` was deleted on 2026-10-27. Other plans and
`benchmarks/lss-opt.md` cite these figures.

**Provenance.**

| | |
|---|---|
| binary | `eco-i35`, a bootstrap fixed point, so the per-`SpecId` join of static and dynamic data is valid |
| flags | shipping defaults of 2026-09-08, all LSS on (incl. LSS_038/039/040) |
| workload | self-compile of `compiler/src/Terminal/Main.elm` |
| static census | `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1` |
| dynamic census | bpftrace uprobes on `eco_apply_closure_eval` and `eco_apply_segmentation_unknown`, caller-attributed by return address |

`eco_apply_segmentation_unknown` recorded zero events. All 933,032,776 generic dispatches went
through `eco_apply_closure_eval`.

**Static: stamping outcomes.** `dispatchUpgraded` 17,174, of which `stampedPapGlobal` 2,135 and
`stampedStaged` 678. Declines:

- `noInstance` 14,109. Of these, 11,462 are `g2global`, the success case where the call is already
  direct. The rest: `g1absentl` 1,439, `g1kernel` 770, `papAmbiguous` 201, `papShapeMiss` 88,
  unrecorded kind 108, `g1accessor` 37, `papChar` 4.
- `blocked` 6,618.
- `bodyMismatch` 1,194.
- `shape` 685, of which `arityOver` 379.
- `abiMismatch` 354.

**Dynamic: who calls the generic path.**

| group | events | share |
|---|---:|---:|
| C. IO monad spine (`andThen` / `map` / `traverse`) | 370,949,194 | 39.8 % |
| D. Elm lambdas (mostly IO continuations) | 247,325,530 | 26.5 % |
| B. C++ kernel calling an Elm closure (`foldImpl` 55.0 M, `JsArray.initialize` 36.1 M, `kernelListMapN` 19.0 M) | 115,980,848 | 12.4 % |
| A. Runtime re-entry (over-application) | 111,208,149 | 11.9 % |
| E. Elm fold / collection callbacks | 61,403,717 | 6.6 % |
| F. Other Elm specs | 26,165,338 | 2.8 % |

Hottest hosts: `System_TypeCheck_IO_andThen` 234.8 M (25.2 %), `System_TypeCheck_IO_map` 99.0 M
(10.6 %), `eco_apply_closure_eval` (re-entry) 92.0 M (9.9 %).

Each `andThen` instance makes exactly two generic dispatches: `ma s0`, where `ma` is a parameter,
and `(f a) s1`, where `f a` mints a closure at run time. The continuation `f a` itself was already
stamped. The two hot sites carried 26,361,474 events each, identical to the digit.

**Its ranking of targets.**

1. Over-application re-entry, 92.0 M. This plan; §3 re-examines it.
2. The kernel callback boundary, 116.0 M: a typed or fast callback entry for the hot kernels.
3. The IO monad, 371 M plus continuations. This is not an LSS problem; see
   `plans/io-monad-dispatch-reduction.md`.
4. `g1absentl`: 1,439 sites, weight not measured. Later shown to be post-mono artifacts in dead
   specs, fixed by `inline.pruneDead`.
5. `blocked` (LSS_018 μ-tie): 6,618 sites, weight not measured. A design question, not a fix.
