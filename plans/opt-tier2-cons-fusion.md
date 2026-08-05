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

**SCOPE (tightened 2026-08-04): this tier contains only transforms that change
the code eco *emits*** — i.e. things that make every compiled program faster,
the compiler included. Hand optimizations of the compiler's *own Elm source*
are a different category: they improve self-compile wall and nothing else, and
they are sequenced separately. The former U-T2.2′
(`toComparableMonoTypeHelper` key building) was exactly that, and moved out to
**`plans/mono-comparable-key-optimization.md`**.

Why the distinction is easy to lose: the `ECO_CONS_SITES` census that ranks
everything here measures **the compiler compiling itself**, a workload that is
simultaneously the product (axis 1) and the benchmark corpus (axis 3). A hot
site in that census does not by itself say whether eco *generates* bad code
for a pattern or whether one compiler function is written badly. Classify
before scheduling.

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

- **~~`toComparableMonoTypeHelper` work-stack loop ≈164.6M (40% of
  symbolized)~~ — SUPERSEDED 2026-08-04, the key work landed first.** It was
  one LIFO push/pop churn loop building `List String` comparable type keys,
  with a matching Custom pool via WorkItem wrappers; a stack, not a
  combinator chain, so unfusable and immune to front-slack amortization (the
  §10/L3 NO-GO). **Not a codegen defect — a compiler-source defect**
  (`Data.Map`/`Data.Set` re-derive the key on every operation), so it was
  **out of this tier**: `plans/mono-comparable-key-optimization.md` K1+K2
  shipped it. **Post-K2 the site is `toComparableFragments` at 158.3M cons**
  (still the #1 cons site, ~10× the next one) — the work stack and its
  `List.reverse` are gone, but the fragment cells themselves remain, and
  that plan's §10 closed K3/K4 as not worth their risk. Two *generalizable*
  patterns extracted from it are recorded as §5 candidates below; the
  WorkItem-unboxing one (§5) is now hand-fixed at this site only, so it
  still stands as a pass.
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
  **Sizing (RE-CENSUSED 2026-08-04 — the key work went first, as the
  double-count warning below required).** `toComparableFragments` is
  **158.3M cons** post-K2 (was `toComparableMonoTypeHelper` ≈164.6M), plus
  the tail-inline share of the ≈150M pool. The key work took its win in
  BYTES, not cons cells: it deleted the WorkItem Custom pool (−61.6M) and
  the `List.reverse` chunk backings (`ListBacking −10.1M/−2,973 MiB`,
  `ConsChunk −28.1M`) while *raising* Cons by 116.7M — so this unit's cons
  pool did not shrink and its headline number stands, but note the two
  overlap at the same site. **Original double-count warning, still live for
  any future ordering:** whichever lands first shrinks the other's headline
  number, and neither may claim the full figure after the fact — re-run the
  census between them. Gates: differential +
  `ECO_HEAP_VALIDATE`, flag-on self-compile byte-identity, full E2E once
  (teed), census re-run.
- **U-T2.2′ — MOVED OUT 2026-08-04, not dropped.** Was "the toComparable
  site specifically". On inspection it is a **category-A** item: the driver
  is `Data.Map`/`Data.Set` re-deriving the comparable on every operation
  (`compiler/src/Data/Map.elm:110`), which no codegen pass can observe, so
  no version of it makes a user program faster. Full analysis, sizing,
  staging (K1–K4) and gates now live in
  **`plans/mono-comparable-key-optimization.md`**. It remains a legitimate
  self-compile-wall unit; it is simply not this tier's kind of work, and it
  no longer gates U-T2.1′. Note U-T2.1′ may still *incidentally* capture the
  site — it is a self-musttail function with a `List` accumulator parameter,
  i.e. a textbook template candidate — which makes it a useful correctness
  and sizing probe for the template pass.
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

## 5. Candidate generated-code units surfaced by the key-site investigation (UNSIZED)

Recorded 2026-08-04 while classifying the former U-T2.2′. Both are genuine
category-B transforms — they would fire on any program eco compiles, and the
compiler's own hot key-builder is merely one instance. **Neither is sized and
neither is scheduled**; each needs a census before it can be admitted as a
unit, exactly like every other item in this series.

- **U-T2.5′ — CSE over pure calls.** Elm is pure and strict, so common
  subexpression elimination of a repeated call to the same function on the
  same arguments is *unconditionally sound* (modulo `Debug.*` ordering, which
  needs the same written policy U-T2.4′ already owes). There is currently
  **no Elm-level CSE pass** in `compiler/src/Compiler/GlobalOpt/` — the only
  CSE in the pipeline is LLVM's, downstream of the boxing decisions that
  matter. The motivating idiom is probe-then-insert
  (`if Set.member (f x) s then … else Set.insert (f x) s`), which is
  pervasive idiomatic Elm and rebuilds `f x` twice. *Census before
  scheduling:* count repeated pure-call subexpressions per definition on the
  self-compile corpus **and** at least one user workload — the tier pattern
  (×4 so far) is that static censuses of this shape collapse at the
  admissibility gate, so expect that outcome and let the data say otherwise.
- **U-T2.6′ — sum-type wrapper unboxing.** A single-field-constructor sum
  used as a work-stack element (`type WorkItem = WorkType MonoType |
  WorkMarker String`) allocates one Custom object per stack entry. The
  explicit-work-stack idiom is the standard Elm workaround for the absence of
  guaranteed deep recursion, so this pool exists in user programs too, and
  Custom is the **largest** true-allocation class (38.6% of 6.52B). *Census
  before scheduling:* how much of the Custom pool is single-field wrappers
  with a bounded, statically-known constructor set — the honest prior is that
  the qualifying population is small, per the tier-1 T1.3.7/T1.3.8 record.

Both interact with `plans/mono-comparable-key-optimization.md` K1/K2: if
either pass ships, the corresponding hand-fix there becomes redundant. That
makes the hand-fixes a cheap *measurement* of what these passes would be
worth — do them first and read the delta, rather than treating them as
competing work.
