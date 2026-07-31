# Eco optimization roadmap — Tier 3: the RC runtime track (v2)

**Status: GATED / DEFERRED — do not start. Reactivation trigger below.**

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
