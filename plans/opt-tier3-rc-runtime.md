# Eco optimization roadmap — Tier 3: the RC runtime track (v2)

**Status: GATED / DEFERRED — do not start. Reactivation trigger below.**

> **Evidence update (2026-08-07, OC3.0a — `borrow-oracle-consumers.md`
> as-built + Run K in `benchmarks/tier2-opt.md`):** the first DYNAMIC
> sizing of this tier's payoff pool. JsArray copy-on-write churn on solver
> self-compile = **34.72 GB = 13.8% of all allocated bytes** (set-clone
> 143.66M calls/23.06 GB, push 95.56M/11.65 GB), ≈68% of array bytes. The
> static uniqueness license (OC3.0b) got **0/198 sites** — every mutation
> site lives inside elm/core's `Array` module with the array arriving as a
> param, so the unique-vs-shared question is interprocedural and exactly
> what the RC-1 `count==1` check answers dynamically. This is the
> strongest quantified case yet for item 3 (arrays into `rcManaged`).
>
> **Evidence update 2 (2026-08-07, the Dict/Set codegen census — Run L in
> `benchmarks/tier2-opt.md`):** the tree half, measured via a
> lowering-time census (`ECO_DICTSET_CENSUS=1` at the build's lowering
> step stamps a gcLeaf bump per `eco.construct.custom` in
> Dict/Set/Data.Map/Data.Set functions; MLIR byte-identical, instrumented
> binary output-identical, +3.5% wall). Solver self-compile:
> **`dict` = 1,518,633,682 spine nodes / 76.68 GB; `set` = 136.79M /
> 3.28 GB (the 1-field `Set_elm_builtin` wrappers — its tree nodes
> attribute to `dict`); Data.Map/Data.Set dynamically negligible (they
> delegate into Dict). Total = 1.657 B nodes / 79.99 GB = 31.9% of ALL
> allocated bytes and 25.4% of all objects — 66% of the entire Custom
> class (38.6%) is RB spine.** Avg node 50.5 B ≈ the 5-field RBNode
> (sanity ✓). This is spine CONSTRUCTION in Dict/Set code — the upper
> bound on reuse-eligible churn; the unique fraction is again the dynamic
> RC-1 question (fresh-build vs update-of-shared needs `count==1`).
> **Combined RC-1/reuse pool: arrays 13.8% + trees ≤31.9% ⇒ up to ~45% of
> allocation bytes** — the Perceus rbtree showcase class, live in this
> workload at scale. Design consequence discussed 2026-08-07 (recorded in
> `borrow-oracle-consumers.md` OC3 as-built): the favored shape is RC as
> a scoped OVERLAY on `rcManaged` classes (uniqueness oracle only, tracer
> stays reclaim authority — saturation benign, letrec closure cycles
> irrelevant), nursery-residency-gated first (sticky-saturate on
> promotion), remembered-set escalation gated on
> `unique_hit`/`promoted_fallback` telemetry; a one-bit sticky "shared"
> flag (store-site sets, no drops) should be sized against full counts
> before committing to the dup/drop op set.
>
> **Evidence update 3 (2026-08-07, the reuse-pair static census — Run M in
> `benchmarks/tier2-opt.md`):** the static half of the reuse question,
> closing the ladder. Per-def, per-SIZE-class pairing of oracle-proven
> would-drops with same-size local allocations: **total pair ceiling
> ≈10.4K sites**, dominated by `cons` (5,962) and 1–2-field wrapper
> customs; **`cus5` — the RBNode class carrying 1.52B dynamic nodes — has
> 28 static pairs vs 4,276 alloc sites.** The old spine arrives via the
> tree param, so its death is caller-side/dynamic — the same
> interprocedural wall as the arrays license (0/198). Consequence:
> **STATIC Perceus reuse tokens (phase-6 item 7) have no population where
> the dynamic mass lives — the correct v2 sequencing is dynamic RC-1
> (`count==1` at the mutation/rebuild kernels) FIRST; reuse tokens remain
> post-v2 at best.** The census triangle is now complete and unanimous:
> dynamic churn huge (Runs K/L: arrays 13.8% + spine 31.9% of bytes),
> static uniqueness license zero, static reuse pairs zero-where-it-counts
> ⇒ the ~45% pool is reachable only through the dynamic overlay.

**Series:** `plans/opt-tier{1..4}-*.md` — see `opt-tier1-aggregate-promotion.md`
for the series header. Supersedes the `borrow-inference-phase{0..6}` series
for sequencing; **`borrow-inference-phase5-rc-optimizations.md` remains THE
implementation spec** for B4/B5 and is not duplicated here.

---

## 0. What this tier is

Everything that needs RC ops in the IR and a GC-coexisting refcount runtime,
bundled in dependency order:

1. **Per-ctor / field-granular precision** — phase-6 item 3 (hard
   prerequisite of recursive decref: `updateCopiedHeapFields`=5,743 sizes
   the record-update hazard).
2. **B4 reification + certifying checker + runtime RC path** — phase-5
   U5.1–U5.4 (the `MonoRcDup/MonoRcDrop` sweep, `Borrow/Reify.elm`,
   `Borrow/Check.elm`, `rcMode` pipeline gate, `RefCount.cpp`, G2
   census↔`ECO_RC_STATS` reconciliation).
3. **Arrays/lists into `rcManaged`** — phase-6 item 2, with the mutation-
   story fork that puts HEAP_005 at stake: *builder-style nursery pinning*
   vs *scoped remembered set* (both options + costs recorded in the
   phase-6 item; decided in the graduated plan).
4. **Then the tuning layer:** mode specialization (item 1;
   `poisonedParams`=133,231 says the ceiling is real but it only pays under
   reification), drop-sliding (item 5; `ltpRefined`=101,011 is its static
   sizing), mutation-aware Stage-C heuristic (item 6).

## 1. Why it is deferred (the evidence, so nobody relitigates)

- The v1 `rcManaged` surface (pointer-free buffers) is **0.05% of
  allocation volume**; `wouldFree`=13,869; the RC-1 candidate set is
  **empty** in v1 (phase-5 fact 10, re-confirmed by the §15.2 kernel
  audit). Full record: `design_docs/borrow-inf-census.md` §2d/§6/§16.
- The dominant cost (tracing GC over Cons/closures) is untouched by v1 RC —
  that mass belongs to tier 2.
- The analysis-toll rule (tier-1 T1-R1) applies doubly: B4 requires the
  oracle at compile time (~15% wall) *plus* RC-op mutator overhead before
  any reclaim pays.

## 2. Reactivation trigger

Open this tier when a **workload demands array-mutation performance** —
in-place `JsArray` update/set beating O(n) copy is an *algorithmic* win for
array-heavy user programs, which is where the RC payoff genuinely lives.
Self-compile wall is explicitly NOT a sufficient trigger (the numbers above
say it never pays there). Secondary trigger: tier-1/tier-2 outcomes leave
generated-code performance as the binding axis and the borrow analysis has
been made cheap enough to run per-build.

## 3. On reactivation, in order

item 3 → B4 (U5.1–U5.4, gate G2) → item 2 (choose the mutation story; amend
HEAP_005 or mint the new HEAP_BUILDER_* variant per the phase-6 item) →
B5 reclaim → items 1/5/6 as telemetry (`ECO_RC_STATS`) directs. The one
future lever recorded beyond the phase plans: RC-world `makeRope` dups its
operands instead of consuming them (caller passes borrowed; RC bump only on
the >32 KiB rope path) — reclaims the `Utils.append` copy case a static sig
cannot (census §15.2 correction).
