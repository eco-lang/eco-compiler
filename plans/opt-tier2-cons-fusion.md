# Eco optimization roadmap — Tier 2: residual list-traversal deletion (cons fusion: CLOSED)

**Status: RESTRUCTURED 2026-08-04 — rebased onto the shipped chunked-list
work (`plans/chunked-list-representation.md`, phases L0–L5 all decided;
`list.chunks` default-ON since the Aug 3 quiet-window wall verdict).
Classic pairwise combinator fusion — this tier's original program — was
measured and CLOSED NO-GO by that plan's own L5 adjacency census. The
census-ranked residual units below are what remains.**

**Series:** `plans/opt-tier{1..4}-*.md` — see `opt-tier1-aggregate-promotion.md`
for the series header and ordering rationale. Supersedes the
`borrow-inference-phase{0..6}` series for sequencing.

---

## 0. What happened to this tier (record, so nobody re-plans it)

As scoped pre-Aug-2 this tier was "list/Cons deforestation": whole-combinator
recognition + fusion of adjacent pairs, on the premise that *"not allocating
the intermediate list at all is the only lever."* The chunked-list plan then
executed the recognition-and-loop-template half of that program under its own
phasing, and measured the fusion half dead:

- **The infrastructure this tier planned to build now exists** (chunk plan
  §6 L1 as-builts): `GlobalOpt/ListCombinators.elm` whole-combinator
  recognition; combinator shunts to chunk-building kernels
  (`Functions.elm listChunksShunt`); the GC-rooted scratch stack
  (`eco_scratch_mark/push_*/finish/finish_fwd/abandon`); backend passes
  `EcoListTemplate` (unwind-cons capture) and `EcoListCursor` (3,191 of
  4,626 whiles walk mixed spines allocation-free); chunk chaining for
  over-cap batches. This was U-T2.2's option (b) — "List-LoopIR at
  emission, BytesFusion precedent" — shipped under another name.
- **The target mass collapsed via a different lever than fusion.** Final
  flag-on trade, now the default baseline: **−4.28% objects, −47.5% Cons
  (737.5M → 387.9M), −24% list bytes, −1.7% RSS, lower minor-GC time in
  every pair, zero measurable wall cost** (true-quiet-window parity, chunk
  plan §6 L1 superseded verdict). Chunks cheapened the intermediates and
  de-allocated the walks instead of deleting them.
- **Gate D-T2 (≥10% of allocation projected) is now unreachable by
  arithmetic:** residual Cons is 388M of 6.21B objects ≈ **6.2%** — perfect
  deforestation of every remaining cons could not clear the gate this plan
  set for itself.

### The fusion verdict (chunk plan §6 L5, Aug 3 2026 — do not re-run on self-compile)

Per-function-scoped adjacency census of the Stage-7a compiler MLIR (an
earlier global-scope scan was invalidated by cross-function SSA-name
collisions: 6,638 apparent pairs → **1,162 real**): `foldl∘reverse` 815
(70% — `foldrHelper`'s internal >500-element fallback, one site per spec,
dynamically rare, already chunk-chain-cheap), `append∘append` 120,
`map∘map` 44, everything else ≤ 40. **No high-value fusible pool exists on
the self-compile workload**; the measured wall profile is dominated by
Custom/Closure churn and non-list work. A speculative `reverse∘reverse→id`
peephole was implemented, measured against the corrected census (0 real
occurrences), and removed.

| killed | by | revive iff |
|---|---|---|
| Pairwise fusion laws / deforestation on self-compile (the original U-T2.1–U-T2.3) | L5 adjacency census (1,162 real pairs, top pool cold) + D-T2 denominator arithmetic (6.2% < 10%) | a workload whose adjacency census shows a hot `map∘map`/`fold∘map`/`concatMap` pool — i.e. user programs; see U-T2.4′ |

## 1. What the residual Cons actually is (chunks-on census)

Post-chaining cons-site tally (`ECO_CONS_SITES` return-address tally on the
flag-on census run; chunk plan §6 L1.3/L3):

- **`toComparableMonoTypeHelper` work-stack loop ≈164.6M (40% of
  symbolized)** — one LIFO push/pop churn loop building `List String`
  comparable type keys; it also drives a matching Custom pool via WorkItem
  wrappers. A stack, not a combinator chain: unfusable, and front-slack
  amortization cannot help a stack (the §10/L3 NO-GO).
- **Sub-4-element lists ≈61M** (kernel `reverse` n<4 cells fallback,
  LTO-inlined into the specs) — below any chunk threshold by design;
  irreducible.
- **Lambda/tail-inline long tail ≈150M** — the tail-inline share is
  capturable by function-level templates (below); the closure-mediated
  foldr-family share (λ≈7.7 papExtend traffic) is uncapturable without
  defunctionalization — the U2b/H7 NO-GO precedents apply. Parked.
- Thin kernel tail: `append` cells 5.8M, `String.split` 5.5M, `map2` 4.8M
  (the L2 Tier-A pool, already converted where it paid).

None of this is fusion-shaped. The units below are the chunk plan's own
data-ranked next levers, adopted as this tier's residuals.

## 2. Units (restructured)

- **U-T2.1′ — function-level accumulator templates (the payoff unit).**
  The slice-2 architecture correction (chunk plan §6 L1.3) is the design:
  eco lowers TCO as `musttail` self-calls, never `scf.while`, so
  accumulator recursion is invisible to loop-level capture — the capture
  point is the **function**: self-musttail functions with an accumulator
  parameter; rewrite non-recursive call sites to `mark/…/finish`; carry
  over the slice-3 bail list (papCreate-referenced, musttail external
  sites, escaping self-call results, non-dominating heads). Mono-level
  template generation in `Functions.elm` (BytesFusion precedent) is the
  recorded alternative altitude if backend capture proves awkward.
  **Sizing:** toComparable's 164.6M plus the tail-inline share of the
  ≈150M pool. Gates: differential + `ECO_HEAP_VALIDATE`, flag-on
  self-compile byte-identity, full E2E once (teed), census re-run.
- **U-T2.2′ — the toComparable site specifically** (likely subsumed by
  U-T2.1′; listed so it cannot be silently dropped). 40% of residual Cons
  plus its Custom shadow in one function. If the generic template bails
  on it, a targeted rewrite is warranted — including the option of
  changing the keying strategy itself (it builds `List String` comparable
  keys; interning/hash-consing the key would delete the pool at source
  rather than allocate it faster).
- **U-T2.3′ — measurement discipline (standing).** Every census and wall
  in this tier runs against the **chunks-ON baseline** (the default since
  Aug 3); the corpus is now flag-on-shaped, so comparisons against
  chunks-OFF need the full `.elm` touch (env-blind harness cache). Walls
  always recorded with their majors (GC-trigger lottery). `elm-aws-codegen`
  canary on any pass that wraps bodies in lets (`annotateCallStaging`
  exponential).
- **U-T2.4′ — user-workload fusion activation (recorded, NOT scheduled).**
  Fusion survives only as a **generated-code quality** feature (series
  axis 3), activated per-workload, never by self-compile evidence:
  - *Activation:* a cheap adjacency census on the target workload
    (`ECO_LIST_REPORT` combinator census + the L5 scoped MLIR adjacency
    scan) showing a hot `map∘map`/`fold∘map`/`concatMap` pool.
  - *Capture point (recorded in L5):* mono-level closure composition +
    re-specialization in GlobalOpt over `ListCombinators` recognition —
    NOT MLIR (lambdas are opaque `papExtend`s by then).
  - *Owed before the first law lands:* the `Debug.log`/`Debug.crash`
    ordering + ⊥-selection policy as an invariant note (fused callbacks
    may interleave differently; producer/consumer ⊥ can shift — both
    acceptable under `--optimize`, but write it down).
  - *Context:* the perf-tune hand-fusions (`++`/`concatMap`/`allRes`,
    −62.4M objects/−5.1%) remain the measured preview of what automatic
    fusion buys when a pool exists; borrow-oracle sharing facts stay
    optional (in-place reuse decisions belong to the tier-3 world).

## 3. Related-but-separate (carried over)

- **TRMC** (tail-recursion-modulo-cons): still out of scope. Chunk
  templates + chaining consumed most of its spine-building value; revisit
  only on user-workload evidence, and note it reduces recursion overhead
  but does not remove allocation.
- **Stale borrow-oracle citation:** the old §0 figure "`List.cons` is the
  #1 owned kernel site (4,175 defaulting call sites)" predates chunks —
  much of that traffic now routes through chunk builders. Re-run the
  borrow census flag-on before quoting kernel-site numbers in any new
  decision.

## 4. Risks (carried over, updated by the as-builts)

- **Inliner interactions are real, twice over:** `MonoInlineSimplify`
  threshold-inlining silently defeated the L1 shunts until the blacklist
  was upgraded to full non-candidacy — any new template/shunt symbol must
  join the Generate blacklist when `list.chunks` is on. Body-copying
  rewrites need `freshenLetBoundNames` (duplicate-let SSA-redefinition
  lesson).
- `annotateCallStaging` exponential (GlobalOpt phase 5, O(2^let-depth)) —
  measure the `elm-aws-codegen` canary per U-T2.3′.
- E2E/elm-tests cache race: serialize; `--target full` deletes
  `bin/eco-compiler` (rebuild via `--target eco-compiler` for census runs).
- Run E2E once, teed, grep the file.
