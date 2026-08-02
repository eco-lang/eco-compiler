# Eco optimization roadmap — Tier 2: list/Cons deforestation

**Status: SCOPING — activates on D-T1's outcome (immediately if D-T1 fails;
after tier-1's U-T1.3 otherwise). Highest impact ceiling of any tier.**

**Series:** `plans/opt-tier{1..4}-*.md` — see `opt-tier1-aggregate-promotion.md`
for the series header and ordering rationale. Supersedes the
`borrow-inference-phase{0..6}` series for sequencing.

---

## 0. Why: the allocation mass IS the GC cost

> **EVIDENCE CORRECTION (2026-07-31, census §18.3):** the "Cons ≈65% of
> ~798M" figure below was an artifact of the inline-alloc counter bypass —
> the complete count (`ECO_INLINE_ALLOC=0` lowering) is **6.52 B objects**
> with **Cons at 10.4% (679M)**; the dominant mass is codegen'd aggregates
> (Custom 38.6% + Closure 22.1% + Tuple2 19.2% = 80%), which belong to
> tier 1's promotion track. This tier's ceiling shrinks accordingly: still
> 679M objects absolute (worth having), but tier 1 now clearly leads and
> the D-T2 gate below should be read against the corrected 6.52 B
> denominator. True promotion rate is 2.5%, not 19.9%.

- ~~Cons ≈ **65% of ~798M objects** per self-compile~~ (corrected above).
  Tracing GC is ~29% of runtime self-time / ~25% of wall — driven by the
  aggregate classes per the corrected profile (root-scan 14.5% +
  evacuate/mark 14.4%).
- **Calibration (perf-tune loop, 2026-07-29/30):** nine targeted fusions
  removed −62.4M objects (−5.1%) and −41 minor GCs — and wall stayed
  noise-bound. Conclusion: this tier only pays if it is *systematic* —
  tens-of-% object reduction, not single digits. That is the bar D-T2 sets.
- The borrow oracle confirmed the shape empirically: `List.cons` is the #1
  owned kernel site (4,175 defaulting call sites) and Cons cells escape —
  neither RC nor stack promotion touches them. **Not allocating the
  intermediate list at all is the only lever.**

## 1. Why it's hard, and why legality is NOT the hard part

- **Recognition is the hard part:** `List.map` is a recursive `foldr` —
  per-op rewriting never sees a fusable "loop". Fusion needs
  **whole-combinator recognition** (the cons-reduction investigation's
  conclusion): treat `map/filter/foldl/foldr/concatMap/append/indexedMap/
  reverse/map2` as known symbols and fuse adjacent pairs/chains.
- **Legality is nearly free:** Elm is pure and strict — intermediate lists
  are semantically unobservable, so `map f ∘ map g ⇒ map (f ∘ g)` etc. are
  unconditionally sound up to two caveats to state as policy: (a)
  `Debug.log`/`Debug.crash` ordering inside fused callbacks may interleave
  differently; (b) a non-terminating producer fused with a partial consumer
  can change which ⊥ you hit. Both are acceptable for `--optimize` (record
  as an invariant note when implementing). The borrow oracle's sharing
  facts are **optional** here — useful later for in-place reuse decisions,
  not needed for deforestation soundness. Per tier-1's T1-R1, that keeps
  this tier free of the ~15% analysis toll.

## 2. Existing infrastructure to build on (do not invent)

- **`Generate/MLIR/BytesFusion/{Emit,LoopIR,Reify}.elm`** — the in-repo
  template: recognizes codec chains at emission and lowers them to a loop
  IR. A List-LoopIR would mirror this shape.
- **`GlobalOpt/Staging/{ProducerInfo,GraphBuilder,Rewriter,Solver,
  UnionFind}.elm`** — the call-staging rewrite infrastructure; a
  Mono-level rewrite-laws pass would live beside it.
- **`AbiCloning`** keyed specialization — for fused-combinator
  specializations if the strategy needs per-shape clones.

## 3. Units

- **U-T2.1 — combinator-chain census (first, cheap, decisive).** A
  census-only GlobalOpt fold (same posture as the borrow census) counting
  fusable adjacencies in the Mono graph: `map∘map`, `map∘filter`,
  `foldr/foldl∘map`, `concatMap`, `append`-of-producer, `indexedMap`,
  `reverse∘X`, `map2`, consumer-in-case-of-producer. Static counts + the
  hot-def list; weight against the Cons allocation share. **Gate D-T2:**
  projected object reduction from the top-N chain shapes **≥10% of total
  allocation** → build; else record and stop (tier 4).
- **U-T2.2 — strategy decision (short design doc).** Two candidates:
  (a) **rewrite laws at Mono level** (build/fold-style pairwise laws over
  known combinator symbols — simpler, catches adjacent pairs, no new IR);
  (b) **List-LoopIR at emission** (recognize whole chains and lower to an
  index/accumulator loop à la BytesFusion — bigger, catches long chains
  and mixed consumers, kills the closure allocations of the combinators
  too). Choose from U-T2.1's shape distribution; (a) can ship first and
  (b) subsume it later.
- **U-T2.3 — implement the top-N shapes** behind a config flag
  (hash-relevant this time — it changes output), corpus + self-compile
  gates, one shape at a time with the census re-run per shape.
- **U-T2.4 — measure & verdict.** Objects allocated, minor-GC cycles,
  promotion count, interleaved ×3 walls with majors, plus `elm-aws-codegen`
  canary (deep-let-chain pathology). Related-but-separate follow-on to
  record: TRMC (tail-recursion-modulo-cons) for spine-building loops —
  reduces recursion overhead and enables `evacuateListSpine`-friendly
  contiguous spines, but does not remove allocation; keep out of scope
  until the fusion verdict is in.

## 4. Risks

- **Inliner interactions:** fused shapes must survive (or run after)
  `MonoInlineSimplify`; the duplicate-let-name SSA-redefinition lesson
  applies to any rewrite that copies bodies (`freshenLetBoundNames`).
- **`annotateCallStaging` exponential gotcha** (GlobalOpt phase 5,
  O(2^let-depth) on deep chains): a fusion pass that wraps bodies in lets
  can re-trigger it — measure the canary.
- Corpus is flag-off-shaped and the harness cache is env-blind — touch all
  test `.elm` before flag-on gates; run E2E once, teed, grep the file.
- `Debug.*` ordering / ⊥ policy must be written down (invariant note)
  before the first law lands.
