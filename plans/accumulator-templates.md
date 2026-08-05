# Function-level accumulator templates — scratch-stack capture of TCO list builders

**Status: NEW 2026-08-05, UNSIZED. Recognition census (AT1) before the
rewrite. The infrastructure is ~80% built; the *justification* is the part
that needs work.**

**Provenance:** `plans/opt-tier2-cons-fusion.md` U-T2.1′ (that plan's
nominated payoff unit), rebased onto the retention finding. The architecture
correction it depends on is `plans/chunked-list-representation.md` §6 L1.3
slice 2.

> **CATEGORY B — a backend pass, so it changes the code eco emits for every
> program.**

---

## 0. The idiom and the transform

The standard Elm tail-recursive list builder:

```elm
go acc list =
    case list of
        [] -> List.reverse acc
        x :: rest -> go (f x :: acc) rest
```

N iterations allocate N cons cells; `List.reverse` then walks and rebuilds
the whole spine. Nothing observes the partially-built accumulator — it is
pure intermediate state.

**The transform:** don't build a spine while accumulating. Push each element
onto the runtime's GC-root-registered scratch stack
(`eco_scratch_push_boxed` / `_push_scalar`), leave the accumulator parameter
threading through **unchanged** (it becomes loop-invariant), and materialize
once at the end via `eco_scratch_finish`, which builds
`entry[top-1] :: … :: entry[mark] :: next` as a single dense chunk (falling
back to cells when small / over-cap / chunks-off, reproducing exactly the
spine the loop would have built). Push order equals cons order and `finish`
reverses, so the reconstruction is exact and multi-cons iterations and
conditional prepends need no special handling.

## 1. Why "function-level" — the correction this plan exists to encode

This was first built as a **loop**-level pass: `EcoListTemplate` phase 1
rewrites `scf.while` loops whose iteration argument is a pure
cons-accumulator, including conditional chains through
`scf.if`/`scf.index_switch`/`eco.case`.

**It captured ZERO loops on the entire compiler** — 4,626 `while`s, 15,673
value-typed iteration arguments, not one accumulating via inline cons
(`chunked-list-representation.md:456`).

The reason is architectural and is the single most important fact in this
plan: **eco lowers TCO as `musttail` self-calls at the MLIR level, never as
`scf.while`.** Accumulator recursion never materializes as a loop, and the
accumulator update crosses `eco.call` (1,611 sites) / `eco.papExtend` (1,690
sites) boundaries where the cons lives inside the callee.

In eco, **the function *is* the loop.** So the capture point must be:

- a self-`musttail` function with a `!eco.value` parameter such that every
  self-call passes that parameter extended by a cons chain (possibly through
  `scf.if` / `index_switch` / `eco.case` yields);
- body rewrite: push where the cons was, pass the parameter through
  untouched;
- **non-recursive** call sites rewritten to `mark` / call / `finish`.

## 2. What already exists (verified against source, 2026-08-05)

`runtime/src/codegen/Passes/EcoListTemplate.cpp` phase 2 implements the
**mirror image** — cons on the *return* path around a self-call
(`x :: recurse rest`, the foldr/encoder family). It is a direct template for
phase 3:

| machinery | location | reuse |
|---|---|---|
| entry point + shape/terminator checks | `tryRewriteUnwind :729-752` | extend |
| dominance check on cons heads | `:761-769` | as-is |
| module-wide use scan, rejects non-direct/musttail callers | `:771-790` | as-is |
| runtime decl emission (`ensureDecl`) | def `:281`, calls `:796-812` | as-is |
| element-kind unification + scalar bitcast/extend on push | `:814-840` | as-is |
| call-site `mark` / call / `finish_fwd` wrapping | `:844-861` | as-is, but `finish` (reverse) instead of `finish_fwd` |
| chain walk through region ops | `walkUnwind :652` | new argument-side twin |
| phase-1 (`scf.while`) cons-chain validation + `finish` emission | `walkChain :126-280`, `tryRewrite :370-544`, `rewrite :545-611` | **the reverse-order emission half is already correct and directly reusable** — only the *discovery* half is loop-shaped, and that is exactly the half that captures nothing |

Runtime side (slice 2, `RuntimeExports.cpp`): `eco_scratch_mark`,
`push_boxed`, `push_scalar`, `finish`, `finish_fwd`, `abandon` — a
GC-root-registered growable stack with an external root scanner, evacuated
in minor-GC phase 1d. Nesting balances by mark/finish discipline. **This is
why the transform is safe without §10 builder pinning: the growing state
lives outside the heap.**

The pass is a no-op unless a function carries the `eco.list_chunks`
attribute, so chunks-off output stays byte-identical.

## 3. The honest prior — read this before scheduling

**The allocation case for this unit is weak to dead, and it was the unit's
entire original justification.**

- The chunked-list track already ran the controlled experiment at roughly
  twice the scale this unit targets: **−349.6M Cons, −261.9M objects, zero
  wall** (§6 L1 exit gates).
- `EcoListTemplate` phase 2 captured **29 of 55** candidate functions, all
  gates green, byte-identical self-compile — and moved Cons by **−149K**,
  because recursive encoders yield 1–3 elements per call, below the ≥4 chunk
  threshold, so `finish` takes the cells path anyway.
- The residual pool this unit was sized against (`toComparableFragments`
  158.3M cons) is measured *nursery garbage*: K4 removed 143.2M Cons at that
  site and **objects promoted were identical**, wall flat.

Anyone scheduling this on the strength of "158.3M cons, the #1 site" is
repeating the mistake `plans/live-heap-composition-census.md` §0 documents.

## 4. What actually justifies building it

Three arguments, none of which is the cons count:

1. **Retention, not allocation — and it was never measured.** A materialized
   chunk is **one** `ListBacking` + view where the cell spine is N objects.
   If a built list *survives*, the chunk form presents the collector with
   orders of magnitude fewer objects to promote, scan and mark. The chunk
   work's own numbers hint at this and nobody followed up: RSS went from
   +2.5% (slice 1) to **flag-on below flag-off, 5.38 vs 5.48 GB** (slice 4),
   and majors moved. **Chunked lists may already be a retention win that was
   scored as a wall wash because promotion was not instrumented.**
   → **AT0 below makes this the first thing measured, and it costs nothing
   to run.**
2. **Reverse-cancellation deletes a traversal.** See AT3. This is the only
   variant whose win is executed work rather than reshaped allocation.
3. **Category-B value on non-self-compile workloads.** Self-compile is one
   program with one shape. Phase 2 was kept on exactly this reasoning
   ("captures long-chain `x :: recurse rest` patterns that other workloads
   will hit") and that reasoning is sound here too — but it is a bet on
   unmeasured workloads, so it justifies *building cheaply*, never
   *building big*.

## 5. Units

### AT0 — re-measure the shipped chunk work under LH1 (do first; costs a run)

Requires `plans/live-heap-composition-census.md` LH1. Run flag-on vs
flag-off self-compile with the per-tag promotion histogram and compare
promoted `Cons` / `ConsChunk` / `ListBacking`. This is a **zero-code
measurement that may reframe the entire list track** — and if chunks are
retention-neutral too, it is the strongest available argument for *not*
building AT2.

### AT1 — recognition census

Add a phase-3 recognizer to `EcoListTemplate` that reports without
rewriting (`ECO_LIST_TEMPLATE_DEBUG` already has the counter/bail-stats
harness at `:67-88` — extend `BailStats`). Report: self-musttail functions
with a `!eco.value` accumulator parameter; how many pass the full bail list;
and how many are **dynamically hot** (join against the `ECO_CONS_SITES`
tally, or against LH4a's per-tag survival bridge).

The static count is the number every previous unit in this series
over-trusted. **The dynamic join is the deliverable.**

### D-AT — the gate

Proceed to AT2 iff **either** AT0 shows list-class promotion ≥5% of total
promotion, **or** AT1 finds a hot capturable population whose combined
dynamic weight justifies the pass. Static candidate count alone does not
open the gate — phase 2's 29 captures for −149K is the precedent.

### AT2 — the argument-side rewrite

The twin of `walkUnwind`: validate that on every path the self-call's
accumulator operand is a cons chain rooted at the accumulator block
argument; insert pushes at the cons sites; replace the operand with the
block argument itself; wrap external call sites `mark` / call / `finish`.

**Bail list** (inherited from phase 2, all already implemented there):
`papCreate`-referenced functions; `musttail` external call sites (you cannot
insert `finish` after a musttail call); escaping self-call results;
non-dominating cons heads; multi-use cons results; mixed element kinds; more
self-calls in the body than the chain walk accounted for.

### AT3 — reverse cancellation (the variant worth the most)

Recognize `List.reverse <acc>` at the base-case return, drop it, and use
`finish_fwd` at the call site — pushes are already in forward order, so
forward reconstruction *is* the answer. This **deletes a whole traversal**
rather than reshaping allocation, and it is the only part of this plan that
attacks executed work.

Sizing caveat, stated up front: `reverse` is already shunted to a
chunk-building kernel (`Functions.elm listChunksShunt`, count-first: probe
shape → exact backing → view → direct fill), so the deleted traversal is one
bulk pass, not N allocations. The win is real but smaller than the source
reads.

### AT4 — measurement

Per `benchmarks/tier2-opt.md` methodology, against the **chunks-ON**
baseline (default since Aug 3). Record promotion alongside wall and majors.

## 6. Risks

- **Inliner interaction, twice burned.** `MonoInlineSimplify`
  threshold-inlining silently defeated the L1 shunts until the blacklist was
  upgraded to full non-candidacy. **Any new template/shunt symbol must join
  the Generate blacklist when `list.chunks` is on** or the pass will appear
  to work and capture nothing.
- **Retention can go the wrong way here too.** The scratch stack holds every
  element live for the duration of the accumulation. For a long
  accumulation whose result is *discarded incrementally*, that is a live-range
  extension — the same C-R1 hazard `cse-pure-calls.md` §3 describes. AT0/LH1
  is how you find out.
- `annotateCallStaging` exponential — `elm-aws-codegen` canary.
- Body-copying rewrites need `freshenLetBoundNames`.
- E2E/elm-tests cache race: serialize. `--target full` deletes
  `bin/eco-compiler` (rebuild via `--target eco-compiler` for census runs).
- Run E2E once, teed, grep the file.
- **Invariant check is mandatory before touching lowering** — HEAP_037-040,
  CGEN_070/071 were recorded by the chunk work and govern this pass's
  output.

## 7. Gates

Flag-off output byte-identical (attr-gated, so this is by construction —
verify it anyway). Flag-on self-compile fixed point byte-identical.
`ECO_HEAP_VALIDATE` clean. Differential runner. Full E2E once, teed.
elm-tests. Bootstrap both fixed points. Census re-run.
