# Eco optimization roadmap — Tier 4: parked / killed items

**Status: REGISTER — items the evidence says not to do, each with the
number that killed it and the condition that would revive it. Nothing here
is scheduled; nothing here should be re-opened without new evidence.**

**Series:** `plans/opt-tier{1..4}-*.md` — see `opt-tier1-aggregate-promotion.md`
for the series header. Supersedes the `borrow-inference-phase{0..6}` series
for sequencing.

---

| item | killed by | revive iff |
|---|---|---|
| **B5a string/buffer reclaim** (`DropFree` on `rcManaged` v1 buffers) | `wouldFree`=13,869 ≈ 0.05% of allocation; no RC-1 targets (census §2d/§16); RC-op overhead would exceed reclaim | arrays enter `rcManaged` (then it ships as part of tier 3, not alone) |
| **Oracle-coupled reification on self-compile** (any transform requiring borrow analysis at compile time — incl. tier-1's U-T1.4 call-crossing promotion) | the ~15% analysis wall toll vs 1–5% realistic wins (tier-1 §0 economics; T-DECISION-1 off-by-default) | the analysis gets ≳3–5× cheaper (it is single-threaded Elm — no parallel escape), OR the optimization targets user-program runtime where compile cost amortizes |
| **Capture borrowing** (phase-6 item 4) | `capturesForcedOwned`=22,986 is not dominant (vs `poisonedByClosure`=99,530); closure-lifetime ≤ capture-lifetime is genuinely hard (closures escape) | the B3.5 PoisonCause split shows captures dominate a future census AND defunctionalization (E8) has been weighed and rejected |
| **Perceus reuse tokens** (`eco.reset`/`eco.reset_ref`, phase-6 item 7) | post-v2 by design; needs items 2/5/6 shipped and measured first | tier 3 ships and RC-1 telemetry shows the copy-fallback class matters |
| **Always-on borrow oracle default** (`borrow.enabled=True` per-build) | T-DECISION-1: ~15% wall ≫ the 3% gate; no production consumer exists | a standing consumer lands (tier-3 reactivation) or the analysis cost collapses |
| **U2b / ECO_ARITY_RAISE** (HOF-elimination leftover, recorded here for completeness) | −13.5% events but +55% slower (HOF plan memory) | never, absent a fundamentally different design |
| **A4 extensible-record store-flatten** (monosolver leftover) | +1.12% slower Stage-7a, all gates green — a measured regression | never re-attempt as-was |

## Housekeeping (not optimizations, just owed)

- **Delete the `ECO_BORROW_CENSUS0` throwaway** (flag + fold:
  `Compiler/Eco/Config.elm` `borrowCensus0`, `Builder/Eco/Config.elm`
  `applyBorrowCensus0Override`, `Builder/Generate.elm` fold) — was due when
  the B2 real census landed; superseded by `ECO_BORROW_REPORT=1`.
- The declared-but-unemitted census counters (`lambdaSigNoSigReads`,
  `meetDegraded`, PoisonCause split, `rc1CrossingFlows`) stay as-is unless a
  tier-3 reactivation needs them wired (census §17.4 records the drift).
