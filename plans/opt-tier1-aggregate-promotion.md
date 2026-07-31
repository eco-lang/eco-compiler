# Eco optimization roadmap — Tier 1: escape sizing + aggregate/scalar promotion

**Status: ACTIVE — the do-now tier.**

**Series:** `plans/opt-tier{1..4}-*.md` is the active optimization planning
surface, ordered by expected impact on (1) self-compile wall, (2) GC/heap
traffic, (3) generated-code performance. Decided 2026-07-31 from the borrow
census (`design_docs/borrow-inf-census.md` §16–§17). It **supersedes the
`plans/borrow-inference-phase{0..6}` series for sequencing**; those files
remain the implementation specs / as-built records the tiers cite.

| tier | file | theme | status |
|---|---|---|---|
| **1** | `opt-tier1-aggregate-promotion.md` | escape sizing + aggregate/scalar promotion + kernel sigs | **ACTIVE** |
| 2 | `opt-tier2-cons-fusion.md` | list/Cons deforestation | SCOPING (activates on D-T1) |
| 3 | `opt-tier3-rc-runtime.md` | RC runtime: arrays, B4/B5, mode-spec, drop-sliding | GATED (v2) |
| 4 | `opt-tier4-parked.md` | parked/killed items + reactivation triggers | REGISTER |

---

## 0. Why this tier, and the economics that shape it

**Evidence** (`design_docs/borrow-inf-census.md` §15.1/§16): the shipped
borrow oracle proves `nonEscapingOwned = 1,961,771` resources (**46.7%** of
all, 69.3% of owned) are owned, un-aliased (`α=∅`), not returned, and
lifetime-local — i.e. candidates for never materializing on the heap. That is
**~140×** the v1 string-RC target by count, the largest v1-viable signal the
oracle produced. Honest bracket: it is an **upper bound** (no transitive
store-into-escaping-container closure yet), and the dynamic weight points
down — the hot allocation classes (Cons ≈65%, closures) mostly *escape*, so
the realized win concentrates in short-lived tuples/records.

**The analysis-toll constraint (load-bearing, shapes every unit below).**
Running the borrow analysis costs **~15% of Stage-7a wall** (perf-tune-loop
measurement 2026-07-29/30; consistent with the 4:04 report-on census run vs
~3:30 baselines). At the bootstrap fixed point the compiler both *pays* the
analysis and *gains* the optimization, so an oracle-coupled transform must
win ≳15% wall just to break even on self-compile — far above this tier's
realistic 1–5%. Therefore:

> **Design rule T1-R1:** tier-1 transforms must be **oracle-free at compile
> time**. Elm is pure and strict — sharing is semantically unobservable, so
> scalar replacement / unpacking of aggregates is *sound* from purity plus a
> cheap local dataflow check; the borrow oracle is used only **off-line, in
> census mode** (zero standing cost) for sizing, candidate discovery, and
> validation. Oracle-coupled reification is parked in tier 4 until the
> analysis is much cheaper or the target workload is not self-compile.

**What already exists (do not rebuild).** The backend has a mature
value-aggregate promotion pipeline — invariant **REP_AGG_001**:
`!eco.tuple2/tuple3/record/custom/cons/closure_env` SSA aggregate types,
introduced by `EcoUnboxedAggSpecialize` (intra-function) and
`EcoUnboxedAggCrossSpec` (cross-function ABI promotion; Direct multi-return
≤3 all-primitive fields, sret for `!eco.value`-carrying results;
`EcoFlattenAggBoundary` + `EcoBoxAggregateOperands`), eliminated by SROA
before RS4GC. The 798M-object / GC-29% profile is measured **with this
pipeline on** — so this tier targets what it *doesn't* catch, and the
invariant itself records the seam: *"recursive cross-spec ABI promotion plus
recursive strip-aggregates … deferred to Phase 2 of the same plan."*

---

## U-T1.1 — Storage-transitive escape closure + per-class weighting census

The sizing step everything else gates on. Pure analysis, census-only,
graph-inert, off by default — same posture as the shipped oracle.

- **Escape closure:** extend the Phase-6 readback (new
  `Borrow/Escape.elm`, or a section of `Borrow.elm`) with a transitive
  closure: seed the escape set with result resvars, `LParams`-reaching
  resources, closure captures, and owned-unknown call operands, then
  propagate through the existing DSU storage classes and `Get` edges —
  a value stored into an escaping container escapes. The DSU already links
  these classes (census §15.1), so this is a union/mark pass, not new
  machinery. Output: `nonEscapingOwnedLB` (the tight lower bound).
- **Per-class histogram:** bucket the surviving candidates by shape
  (tuple2/tuple3/record-N/custom-ctor/cons/closure/string) and static size
  bound, plus a per-def top-sites list (mirror `renderKernelAudit`).
- **Dynamic weighting:** join the static classes against the runtime
  allocation profile (the GC stats exit dump's per-tag counters +
  allocation-size histogram; `ECO_INLINE_ALLOC=0` census build if per-site
  attribution is needed) → **promotable share of allocation volume**,
  specifically the share *not already* captured by the REP_AGG_001 pipeline.
- **Gates:** report-on == report-off byte-identical (`--text-mlir`); full
  E2E once, teed; `BorrowStats` stays ≤32 fields (currently 27 — put the
  histogram behind a Dict field, as `kernelDefaultedNames` does).
- **Reconfigure** `cmake --preset build` if a new `Borrow/*.elm` is added.

### D-T1 — the tier decision gate

Proceed to U-T1.3 iff the weighted promotable share (classes the existing
value-agg pipeline misses) is **≥5% of allocation volume**. Record the
per-class table in `design_docs/borrow-inf-census.md` as §18 either way.
If the gate fails, tier 2 (cons fusion) jumps ahead and this tier reduces to
U-T1.2 + the census record.

## U-T1.2 — `KernelSigs` allowlist growth (cheap, parallel, enabler-only)

Phase-6 backlog item 9 (see `plans/borrow-inference-phase6-v2-backlog.md`
for the full item). Top-down audit of the §15.2 reader list
(`Bytes.getStringWidth`=696, `Crash.crash`=461, `JsArray.foldl/foldr/map`,
`List.map2/sortBy/sortWith`, `String.slice/uncons/toLower/words/trim/
toUpper/all`, `File.*Exists`, `Env.lookup`, `Bytes.width`) — ~2–3K
recoverable sites of 13,230; each row source-verified like the phase-0 §3a
audit; **whitelist-only** (unknown ⇒ owned; a blacklist is unsound). No
direct wall win (nothing consumes the oracle in production) — its value is
census precision, larger U-T1.1 candidate sets, and documented kernel
aliasing contracts. Gates: `elm-tests` + byte-identity.

## U-T1.3 — Widen aggregate promotion (the payoff unit; gated on D-T1)

Three sub-seams, in order of increasing reach — all oracle-free per T1-R1,
all guided by U-T1.1's per-class table:

1. **Finish REP_AGG_001's deferred Phase 2** (backend): recursive
   cross-spec ABI promotion + recursive strip-aggregates, so GC-pointer-
   carrying inner `make.*` cases stay unboxed instead of falling back to
   `eco.to_heap`. The seam, its passes (`EcoUnboxedAggCrossSpec.cpp`,
   `EcoFlattenAggBoundary.cpp`, `EcoBoxAggregateOperands.cpp`), and its
   constraints (CGEN_061/064/066/067) are already pinned in the invariant.
2. **Mono-level scalar replacement of locally non-escaping constructs:**
   a GlobalOpt rewrite replacing construct→project chains (tuple/record
   built and only destructured within the def, never returned/stored/
   captured/passed) with direct value flow. Soundness = purity + the local
   check; no oracle. Must respect MONO_029 layout connectivity and
   FORBID_OPT_001 (representation-equivalence for any boxing removal) —
   read `design_docs/invariants.csv` REP_*/CGEN_* before building.
3. **Multi-return unpacking via `AbiCloning`** (the State-threading
   killer): when every call site of a tuple-returning specialization
   immediately destructures, clone the callee (existing keyed-
   specialization infra, `GlobalOpt/AbiCloning.elm`) to return components
   through the REP_AGG_001 Direct/sret ABI. Purity makes it sound whether
   or not the callee's tuple was fresh; profitability is what U-T1.1's
   class table establishes. Watch FORBID_OPT_003 (no CAF-slot sharing
   across clones) and the AbiCloning singleton-REP lesson.

**Gates per sub-seam:** full E2E once (teed, grepped); new TestLogic unit;
**allocation-census delta** (objects allocated ↓, minor GC cycles ↓ — the
point of the tier); interleaved ×3 self-compile walls with majors recorded;
corpus `.elm` touched before flag-on legs. Perf-tune lesson applies: only
*remove* allocation; never add fixed overhead to a hot path.

## U-T1.4 — Oracle-driven reification (recorded, NOT scheduled)

Call-crossing borrowed aggregates (promote across a call because the callee
signature proves `PBorrowed`) would need the oracle at compile time — the
~15% toll. Parked in tier 4 with explicit reactivation conditions. Recorded
here only so U-T1.3's scoping doesn't silently absorb it.

---

## Risks / standing constraints

- REP_AGG_001 amendments are load-bearing and subtle (statepoint/FCA
  constraints, kMaxDirectFields=3 SelectionDAG bug) — backend work must
  re-read the invariant + CGEN_064 first.
- 32-field GC-scan cap on self-compiled records (`BorrowStats` at 27).
- `MonoGraph.callEdges` is empty at Phase 6 — U-T1.1 reuses the borrow
  driver's re-collected edges.
- Major-GC trigger lottery: never report a wall without its majors.
- E2E/elm-tests cache race: serialize; `--target full` deletes
  `bin/eco-compiler` (rebuild via `--target eco-compiler` for census runs).
