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

**What already exists — CORRECTED v2 (2026-08-02 full source audit; see
U-T1.3's inventory for the verified detail).** The escape-analysis
**passes** are deleted, but far more of the old work survives than the
07-31 note implied: the **entire mechanism layer** was deliberately
retained (`design_docs/globalopt/borrow-inference-design.md` §2.3) —
all six aggregate types, all nine `eco.make.*`/`to_heap`/`from_heap`/
`make.closure` ops with verified lowerings, dual-form projections, the
SROA-before-RS4GC ordering, and the live (consumer-less)
`eco.logical_param_types` metadata channel. What is gone is the five
analysis/transform passes and their flag, deleted after a **measured
failure** (design doc §2.1–2.2): the local escape pass promoted **2 of
30,910** constructs and the ~2,700-LoC CrossSpec worker/wrapper engine
was **net-negative on allocation** (+102.68 MB / +5.5M objects A/B).
Consequences: (a) **every aggregate class currently heap-allocates** —
the census weighting reads directly as unhandled opportunity; (b)
U-T1.3 is a **new consumer for the retained mechanism**, not a re-landing
of the failed analysis — its staging (below) is derived from the
postmortem's defect census; (c) the old ABI knowledge (Direct
multi-return ≤3 all-primitive fields per CGEN_064's SelectionDAG bug,
sret for `!eco.value`-carrying results, store-before-return CGEN_067)
still bounds the design space and phase-3.3 of
`plans/escape-analysis-implementation.md` remains the salvageable spec
for result promotion.

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
  allocation profile — the exit dump's **"Mutator Allocations by Object
  Kind"** per-tag histogram (`GCStats.cpp:1249-1295`,
  `recordTLHAllocation`), which is complete only when the binary is lowered
  with `ECO_INLINE_ALLOC=0` (the HEAP_034 inline fast path writes its
  header word inline and never reaches the counter) → **promotable share of
  allocation volume**. Post-correction there is no already-promoted
  deduction: every class counts.
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

> **D-T1 RESULT (2026-07-31): PASS, decisively — ≈23.5% ≫ 5%**
> (census §18.4). U-T1.1 + U-T1.2 are as-built (census §18.1-§18.2):
> `nonEscapingOwnedLB = 610,685` (14.5% of resources; LB:UB = 31%),
> `kernelSigHits` +2,103. The weighting leg also produced a **major
> measurement correction** (census §18.3): the true allocation profile is
> **6.52 B objects** (not 798M — the HEAP_034 inline path bypassed the
> counter), with **Custom 38.6% + Closure 22.1% + Tuple2 19.2% = 80%**
> of allocation and **Cons only 10.4%** (the "~65%" figure was the
> undercount artifact); true promotion rate **2.5%** (not 19.9%).
> Tuples are the most-promotable class (~35% of tuple2 sites
> non-escaping); records/tuple3 almost always escape. **U-T1.3 is GO**,
> priority order per the weighted table: custom ctor-results (9.0%),
> closures (5.6%), tuple2 (6.8%) — with the intra-def `lit:` slice ~6%
> and the rest requiring `call:`-side promotion (seams 1+3).

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

## U-T1.3 — Aggregate promotion (the payoff unit; D-T1 PASSED → GO)

**Predecessor evidence (read first):**
`plans/escape-analysis-implementation.md` (the 2026-05 master plan, never
successful), `design_docs/escape-analysis-status.md` (the 2026-05-21
survey), and `design_docs/globalopt/borrow-inference-design.md` §2 (the
postmortem + what was deliberately retained). This unit is a **new
consumer for the retained mechanism**, staged so that each of the old
program's five measured defects is structurally avoided, not re-fought.

### T1.3-I — Inventory: what survives in-tree (verified 2026-08-02)

**Alive and load-bearing (the mechanism layer, design doc §2.3):**

| piece | anchor | state |
|---|---|---|
| 6 aggregate types `!eco.{tuple2,tuple3,record,custom,cons,closure_env}` | `Ops.td:113-198`, `EcoTypes.{h,cpp}` | parse/print/convert; verified by fixtures |
| 6 value ops `eco.make.{tuple2,tuple3,record,custom,cons,closure_env}` (Pure) | `Ops.td:2862-2958` | lowering verified |
| `eco.to_heap` (GCRootCarrier; rejects closure_env) | `Ops.td:2960` | lowering verified |
| `eco.from_heap` (Pure) | `Ops.td:3004` | lowering verified |
| `eco.make.closure` (the allocating closure-realiser) | `Ops.td:3034` | lowering verified |
| Full lowering (6 make + ToHeap + FromHeap + MakeClosure + ProjectClosureFromEnv) | `Passes/EcoToLLVMValueAgg.cpp` (~950 LoC), registered `EcoToLLVM.cpp:413` | live |
| Dual-form projections (struct ⇒ `extractvalue`, ptr ⇒ heap path) | `EcoToLLVMHeap.cpp:518,573,818,863,1009` | live |
| `Eco_AnyValueOrAggregate` operand widening — incl. `eco.case`/joinpoint/yield positions | `Ops.td:252,327,360,400` | live (3.4-era; exceeds the old plan's Phase 0–3 scope) |
| SROA-before-RS4GC: `mem2reg → SROA → FoldExtractValue → RS4GC` | `addEcoGCPipeline`, `EcoPtrIntVerify.cpp` | the old Phase-2 prerequisite, permanently satisfied |
| Logical-type channel: `LogicalTypes.elm` + `addLogicalTypesAttr` at 6 `Functions.elm` sites | **66,090** `eco.logical_param_types` attrs in the current self-compile MLIR | **live but consumer-less** — step 3's metadata source |
| 11 `value_*.mlir` fixtures (plain CHECK/CHECK-NOT) | `test/codegen/` | genuinely verified, pass today |

**Deleted (after measured failure):** `EcoEscapeAnalysis.cpp`,
`EcoUnboxedAggSpecialize.cpp`, `EcoUnboxedAggCrossSpec.cpp` (~2,700 LoC),
`EcoFlattenAggBoundary.cpp`, `EcoBoxAggregateOperands.cpp`, the
`-enable-unboxed-agg` flag.

**Stranded/vacuous (test debt, confirmed empirically 2026-08-02):** ~15
`cross_spec_*`/`flatten_*` fixtures still on disk "pass" E2E while
asserting nothing — the harness rebuilds the RUN command with only
`-emit=` (dropping the dead flag, `CodegenIsolatedTest.hpp:240`) and
`CheckPatterns.hpp` parses only `// CHECK:` / `// CHECK-NOT:`, silently
skipping the `CHECK-DAG`/`CHECK-SAME` lines those fixtures rely on
(running `cross_spec_chained_pipeline.mlir` today emits **zero**
`$unboxed` symbols yet reports OK). Matches the debt note in design doc
§2.4.

**Ops to implement: NONE.** All nine ops + types + lowerings exist and
are fixture-verified. All new code is analysis/rewrite passes, front-end
emission logic, harness support, and wiring.

### T1.3-P — The postmortem, and what each defect forces (design doc §2.1–2.2)

The old program's measured results: local pass **2 of 30,910** constructs
promoted (a no-op); CrossSpec accepted 4,741/757 slots of 51,485 and the
A/B was **net-negative on allocation** (+102.68 MB, +5.5M small objects)
for modest footprint wins. The rejection census maps to five defects;
the staging below exists to dodge each one:

| defect (measured) | consequence for T1.3 |
|---|---|
| Wrong altitude: `eco.safepoint` caused 82% of use rejections; papExtend/SCF plumbing fought the analysis | **all escape *decisions* move to Mono altitude** (front end), where safepoints/papExtend/SCF do not exist; MLIR passes only execute mechanical rewrites stamped from above |
| Returns-as-escape (~40% of local verdicts) — binary domain can't say "escapes *into the result*" | returns are handled by **changing the ABI** (step 3 sret/Direct), not by rejecting the candidate |
| `eco.case` scrutinee = escape (Q4) — fatal for Elm, where customs exist *to be cased* | step 2 **erases the case** (ctor inlining + case-of-known-ctor at Mono level) instead of teaching MLIR case about aggregates |
| Callee-eligibility coupling (25K+26K rejections) — analysis entangled with its own transform | no transformation-entangled fixpoint; step 3 selects by **signature shape + call-site syntax** (live logical-type attrs; AbiCloning-style cloning) |
| Closures: papExtend = 89% of producer rejections | closures **explicitly deferred** (step 4 → tier-4 borrow-facts consumer); no closure vocabulary is attempted here |

### T1.3.0 — Mechanism re-validation + debt retirement (small, first)

> **AS-BUILT (2026-08-02): COMPLETE — suite 1608/1608** (1637 − 30
> deleted fixtures + 1 new = 1608, exact). (1) `CheckPatterns.hpp` now
> parses `CHECK-DAG` (positive), `CHECK-LABEL` (positive), `CHECK-SAME`
> (same-line continuation group, in-order after the base match) and
> `CHECK-NEXT` (next-line continuation, one line per NEXT), with an
> **unknown-`CHECK-*:`-variant hard error** (the `CHECK-MLIR` family
> exempted — it is ElmE2ETestBase's second parse) so silent vacuousness
> cannot recur; negative controls verified (planted DAG and NEXT
> failures both caught), positive controls = the previously-vacuous
> `caf_memo_*` NEXT chains and `eco-case-string-patterns` SAME lines,
> now live and green. (2) **30 stranded fixtures deleted** (15
> `cross_spec_*`, 12 `specialize_*`, 2 `flatten_*`,
> `dsl_nested_shape_parse_round_trip`); the three `from_heap_*` fixtures
> KEPT with the dead flag stripped (they pin the retained op); 4 Elm
> behavioral tests kept with HISTORICAL annotations. (3) New
> **`value_sroa_statepoint_llvm.mlir`** — the mechanism proof: a
> mixed-element `!eco.tuple2<i64, !eco.value>` fully dissolved by
> SROA/folding (no insertvalue/extractvalue/alloca/struct residue) with
> the GC-pointer element **in the statepoint's gc-live bundle and
> rebuilt via `gc.relocate`** — the exact FCA-safety property
> REP_AGG_001 promises, now pinned post-RS4GC. (4) **Invariants
> reconciled**: CGEN_025 + REP_AGG_001 stay `enforced` with the stale
> introducer clauses corrected (no producer pass in tree; next producer
> = U-T1.3; SROA law pinned by the new fixture); CGEN_064/066/067 →
> `documented` with a RETIRED-PASS banner (preserved as the U-T1.3.3
> salvage spec; re-ratify to enforced when it lands); CGEN_065 stays
> `enforced`, annotated consumer-less + designated U-T1.3.3 metadata
> source. **Next: T1.3.1.**

- **Fix the harness**: teach `CheckPatterns.hpp` `CHECK-DAG` (unordered
  positive) and `CHECK-SAME` (conjoined substring) — or convert fixtures
  to the supported forms. Then re-run the codegen suite: the stranded
  `cross_spec_*`/`flatten_*` fixtures will **fail honestly**; delete them
  (they test deleted passes) or rewrite the few that document retained
  behavior. The `value_*` set must stay green.
- **Invariant reconciliation**: CGEN_025's make-clause, CGEN_061–067,
  REP_AGG_001 currently describe deleted passes as "enforced". Re-scope
  them to the retained mechanism (ops/lowering/ABI rules), marking the
  producer-side clauses "pending U-T1.3" — per invariants.csv discipline,
  before any codegen change.
- Re-verify `value_*` fixtures under the fixed harness + one fresh
  end-to-end `-emit=llvm` spot-check that SROA still scalarises a
  mixed-element `make.tuple2` (the 3.2-#2 harness idea, one fixture).

### T1.3.1 — Local promotion of the `lit:` slice (tuples/records first)

The escape *decision* is made in the **front end at Mono altitude** — a
cheap, per-def, syntactic use-walk (NOT the borrow oracle: T1-R1 stands;
NOT the deleted MLIR predicate: that measured 2/30,910). A construct is
promotable when its value is only destructured/projected/tag-tested
within the def and never returned, stored into another construct, passed
to a call, captured, or tail-passed — the same sink list the U-T1.1
closure uses, evaluated per-def without solving. Two delivery mechanisms,
decided by a short spike in-step:
  (a) **direct emission** — `Generate/MLIR` emits `eco.make.*` +
  aggregate-form projections for stamped sites;
  (b) **attribute channel** — the front end stamps
  `eco.nonescaping = true` on the construct (mirroring the logical-types
  channel) and a thin new MLIR pass rewrites construct→make (keeps
  `Expr.elm` single-purpose; gives an IR-visible audit surface).
Default (b). Mixed-element aggregates are in from day one (SROA ordering
already satisfied — skip the old Phase-1 all-primitive stage entirely).
**Coverage yardstick** (offline, census-mode oracle): the `lit:` LB
shares — tup2 31.8%, cons 30.4%, rec 2.3% (census §18.2); the
anti-benchmark is the old 2/30,910. Behind `ECO_AGG_PROMOTE`
(hash-relevant), default off until the A/B verdict.

### T1.3.2 — Ctor-call inlining + case-of-known-ctor (the Custom mass)

`ecoConstructCustom` is emitted only inside the ctor's own function
(`Functions.elm:1101/1149`) — so `call:custom`, the **largest class**
(Custom = 38.6% of allocation; 18.9K non-escaping ctor-result sites),
is invisible to any intra-function analysis. Rather than resurrect
cross-function eligibility, **move the construct into the caller**:
- **Inline ctor calls** (bodies are a single construct + return — the
  cheapest inlining decision in the codebase). MLIR-level, on the
  $cap-inlining precedent (mind the REP_LLVM_002 slot-cast-barrier seam
  lessons); or Mono-level if the spike favors it (watch the
  freshenLetBoundNames SSA-redefinition lesson).
- **Case-of-known-constructor at Mono level** (verified absent today):
  `case Just x of …` over a locally-built ctor substitutes the arm
  directly — the construct *and* the tag test erase. Residual non-cased
  ctor results become ordinary T1.3.1 candidates in the caller; even
  still-escaping ones gain the caller's HEAP_034 inline-alloc diamond
  and lose the call overhead.

### T1.3.3 — Result promotion via the salvaged sret ABI (the `call:` tuple slice)

**Salvage phase 3.3 of the old plan verbatim as the ABI spec** — it is
fully worked out and was never the failing part: per-result
`ResultAbi ∈ {Direct, Sret, Boxed}`; Direct multi-return for
all-primitive ≤3 fields (the CGEN_064 SelectionDAG cap); **sret** (plain
addrspace-0 slot pointer, store-before-return with no intervening
statepoint, CGEN_067) for `!eco.value`-carrying results; wrapper
reloads fields into ordinary relocatable SSA. Metadata source: the
**live** `eco.logical_result_types` channel. What is *not* recreated:
the CrossSpec DAG/SCC eligibility fixpoint (the callee-coupling defect).
v1 selection is deliberately narrow and syntax-driven at Mono altitude:
leaf + directly-self-recursive functions whose logical result is a
tuple/record and whose **every** call site immediately destructures —
cloned via the AbiCloning discipline (FORBID_OPT_003: no CAF-slot
sharing; singleton-REP lesson), call sites rewritten to the clone.
`EcoFlattenAggBoundary` is recreated **only if** param-side promotion
later joins (results don't need it — sret/Direct never put an aggregate
type on the boundary). Validation instrument: the 3.2-#2 post-RS4GC
`-emit=llvm` FileCheck harness (salvaged idea, small).

### T1.3.4 — Closures: deferred (recorded, not scheduled)

`lit:clo`/`call:clo` (5.6% weighted) stay out: closure envs were 89% of
the old rejection mass, the capture-ABI surface (`$cap`/`$clo`,
REP_CLOSURE_*) is the riskiest in the backend, and the honest path runs
through borrow-facts export (tier 4 / U-T1.4). The old plan's Phase-4
plumbing (`closure_env` type + ops + lowering) stays warm in-tree.

### Order & expected yield

`0 → 1 → 2 → 3` (4 parked). Step 1 alone targets the ~6% intra-def
`lit:` slice; step 2 opens the 9.0%-weighted `call:custom` class; step 3
the 6.8%-weighted `call:tup2` class (census §18.4). Steps are
independently shippable and independently measurable; each failure mode
(harness rot, predicate coverage, inline seams, statepoint discipline)
is isolated to the step that owns it.

**Gates per step:** full E2E once (teed, grepped); pinned codegen
fixtures under the FIXED harness; **A/B per-tag allocation census**
(`ECO_INLINE_ALLOC=0`-lowered binaries — Tuple2/Custom/Record counts
must visibly drop; the direct proof the transform fires); bootstrap
fixed point (this changes codegen); `ECO_HEAP_VALIDATE` run; interleaved
×3 self-compile walls with majors recorded; corpus `.elm` touched before
flag-on legs. Perf-tune lesson: only *remove* allocation; never add
fixed overhead to a hot path. Default-on only on a benchmark verdict
(the A4 lesson: all-gates-green ≠ faster).

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
