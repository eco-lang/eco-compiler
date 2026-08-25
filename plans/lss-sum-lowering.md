# Sum lowering: tagged-union closure representation over LSS sets — OUTLINE

**Status: OUTLINE (2026-08-23, user-commissioned). This is a decision record
and obligations register, deliberately NOT implementation-ready. It exists so
the Flavor-B decision and its reasons are captured now; the detailed plan gets
written after its prerequisites (below) land.** Companion:
`plans/lss-gap2-callarg-transport.md` (the analysis-side feedstock; its §6
records the obligations this plan inherits).

## 1. Motivation

- Closure dispatch was ≈20% of wall in the Phase-5a sampled census
  (lss-set-write-substrate track; re-measure at plan time — the number
  predates LSS_024/025).
- LSS exploitation today is **singleton-only**: a 1-member set can
  devirtualize (AbiCloning fast path, LSS_025 post-settle devirt, E9.1);
  every multi-member set falls back to indirect dispatch. The size-sweep
  census (2026-08-22, `/work/lss-knob-sweeps-report.md`) measured 1,193
  multi-member sets with width ≤ 8 covering 94.6% — small sums dominate.
- GAP-2's transport exists to grow the concrete-set population at consumers
  (the 77.5% inherited-⊤ mass). Sum lowering is the consumer that turns
  those sets into machine wins beyond the singleton case.
- Sum lowering = compile a k-member set as a tagged union: a small tag plus
  a per-member capture payload; a call through the value becomes a switch
  over the tag with k direct calls, each inlinable. This is the lowering
  model of the lambda-set-specialization paper, and what Roc ships.

## 2. The decision: Flavor B, via lowering-time agreement closure

Two flavors were considered (discussion recorded 2026-08-23):

- **Flavor A — switch-on-identity, representation unchanged.** Closures
  stay id+captures heap objects; a call site with a known set compares the
  stored identity against each member and branches to direct calls. No
  producer/consumer agreement is needed — only the call site's own set
  matters, and directed-flow forward completeness already guarantees that.
  Buys direct calls, inlining, branch prediction. Does NOT buy the big
  prizes: closure-allocation elimination, inline payloads, no function
  pointer.
- **Flavor B — true tagged-union re-representation. CHOSEN.** The set
  determines the VALUE's layout (tag + per-member payload). This is where
  allocation elimination and unboxed captures live.

**Why B is compatible with our directed analysis (the Roc objection,
answered).** Roc's new compiler rejected directed set flow because a set
determines layout and one-way inclusion permits two layouts for one value,
forcing re-tag coercions at flow edges (`roc/reunify.md` §12.4 item 2); they
kept symmetric unification so producer and consumer always agree. We keep
the directed analysis anyway and restore agreement where (and only where)
layout needs it: **agreement closure at lowering time**. For each group of
function-typed positions selected for re-representation, compute the
connected value-flow region over the MONOMORPHIZED program, union the
member sets across the region, and give the entire region that one set and
one layout. Consequences:

- One region = one set = one layout: producer/consumer agreement holds by
  construction; no coercions exist.
- The precision cost (a producer's narrower set widens to the region
  union) is local to re-represented regions; the analysis keeps its
  directed precision for every other consumer (devirt licensing, borrow
  inference, key sharpening).
- Re-tag coercions at region boundaries are REJECTED for v1 — Roc's own
  conclusion, plus our GC/stackmap and mono interaction costs.
- The paper's third annotation channel `(λ…) as σ` (target sets at
  abstraction sites, 146:6 bullet 3 — the agreement half Eco has no analog
  of, GAP-2 plan §6 loss item 5) is exactly what the region union
  reconstructs: each member's CONSTRUCTION site learns the region's full
  set and builds the region's representation (its tag) directly.

## 3. Design sketch (to be expanded in the real plan)

- **Where:** after mono settle (the LSS_025 settle point precedent), on
  monomorphized artifacts — every position carries a `Mono.LSet`/`LTop`
  annotation and every member has (or fails to have) a resolvable instance.
- **Region construction:** nodes = function-typed positions (params,
  results, locals, heap fields, ctor slots); edges = value flow
  (arg→param, result→use, store/load, case binding). Union-find; region
  set = union over the region; canonical tag order = sorted member ids
  (determinism — no iteration-order or address dependence).
- **Eligibility (v1 conservative; any failure → region stays boxed with
  today's representation):**
  - every member instance-resolvable with a known capture layout —
    grounded `g|`/`c|`/qualified ids only; a raw `l|` member disqualifies
    (see prerequisite 3);
  - no `LTop` anywhere in the region;
  - region width k ≤ cap (start aligned with `maxSetSize` = 8);
  - no kernel-ABI crossing (LSS_004 boundary positions force boxed in v1);
  - no escape into ⊤-annotated containers.
- **Representation:** tag + payload; 0-capture members can embed
  pointer-tagged (the null-cons embedding precedent — nullary ctors as
  embedded HPointer words). Requires a HEAP_*/REP_* invariants delta and
  the heap-validate suite extended to the new shape.
- **Call lowering:** switch(tag) → k direct calls, each with the member's
  statically known capture layout.

## 4. Obligations inherited from GAP-2 (hard prerequisites, not notes)

- **A false-complete set here is a miscompile, not a missed optimization**:
  a switch with a missing branch. GAP-2's D0 hardening (∅-as-source fixed),
  its declined-class ⊤-reachability invariant, and the four-legs forward
  completeness argument (GAP-2 plan §4) must be landed and gated BEFORE any
  region is re-represented. Debug builds keep a trapping default branch
  with diagnostics; release builds may drop it only after the battery has
  soaked.
- Producer/consumer agreement: by construction (region closure) — but the
  region builder itself becomes soundness-relevant code and needs its own
  invariant rows.

## 5. Sequencing

1. GAP-2 D0 + D1 + D2 land and flip (feedstock + honesty).
2. Budget-512 flip (already a GAP-2 prerequisite).
3. The `l|` resolvability story: raw `l|` members must become
   instance-resolvable (the LSS_017-v2 / fork-qualified-members direction)
   or l|-carrying regions stay boxed. Sizing question for this plan's own
   Phase 0: what fraction of multi-member sets are all-resolvable, weighted
   by dispatch heat (overlay the dispatch census on region call sites)?
4. Then this plan's Phase 0 census: region count, width distribution,
   disqualification causes (LTop / raw-l| / kernel / width), heat overlay.
   Stop condition: if heat-weighted eligible regions are negligible, park
   and fix the dominant disqualifier first.
- Staging note: Flavor A could ship earlier as a low-risk interim
  exploitation of multi-member sets (no representation change). Decision
  deferred to the detailed plan — if B's timeline is short, skip A rather
  than carry two lowering surfaces.

## 6. Open questions (for the detailed plan)

- Region granularity: whole-program union-find may over-merge (one hot
  narrow region absorbed into a cold wide one). Sets of different type
  shapes never merge (eqLayout), but same-shape merging may still need a
  growth cap or SCC-local regions.
- PAP/under-application of a summed value (spineArity/LSS_025 PAP notes) —
  re-box at the boundary, or disqualify regions with PAP flow in v1?
- Borrow/RC interplay: inline payloads change ownership shape
  (opt-tier3-rc-runtime overlay design).
- Mixed member classes: kernel (`k|`) members likely disqualify v1.
- GC: stackmap entries and heap layout for inline payloads; interaction
  with the contiguous nursery fast path (HEAP_042/043).

## 7. Non-goals (v1)

- Re-tag coercions / cross-region conversion of any kind.
- Re-representing regions containing ⊤ or unresolvable members.
- Any analysis-side change (this plan consumes sets; GAP-2 produces them).
- Symmetrizing the analysis (explicitly rejected — agreement is
  reconstructed at lowering time only where layout demands it).
