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
| 2 | `opt-tier2-cons-fusion.md` | residual list-traversal deletion (pairwise fusion CLOSED NO-GO by the chunked-list L5 census) | RESTRUCTURED 2026-08-04 |
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

> **AS-BUILT (2026-08-02): SHIPPED, all gates green; v1 = tuple2/tuple3,
> straight-line shapes.** Delivery spike chose **(a) direct emission** over
> the (b) attribute channel: (b) would re-fight the postmortem's plumbing —
> a construct→make MLIR rewrite must also scrub the promoted value from
> other ops' GC-root-hint operand lists (type mismatch otherwise), while
> (a) gets root-hint correctness free from the type system
> (`liveEcoValueVars` collects only `!eco.value`-typed vars). **Zero C++
> changes** — the retained lowering + `Eco_AnyValueOrAggregate` machinery
> absorbed everything. As built:
> `Config.aggPromote` (+ hash token `aggp`, env `ECO_AGG_PROMOTE`, JSON
> field, default off) · `Expr.tupleBinderPromotable` — the Mono-altitude
> syntactic walk, **alias-aware**: `let (x,y) = t` desugars to
> `let _v = t; x := _v[0]; y := _v[1]`, so the walker threads a
> candidate∪alias set scope-wise (a dedicated recursion, not foldExpr, so
> the sanctioned alias RHS read is exempt) · `generateTupleCreateValue`
> (slot discipline mirrors the heap layout exactly) ·
> `Ops.ecoMakeTuple2/3` + `ecoProjectTuple2/3Agg` (aggregate
> `_operand_types`; `aggTupleType` renders `NamedStruct
> "eco.tuple2<...>"`, which text AND bytecode emit verbatim — no MlirType
> ADT change) · dual-form dispatch in `Patterns.generateMonoPathHelper`
> (aggregate root ⇒ Agg builders; decider paths inherit it for free).
> **Gates:** unit `TestLogic/Generate/AggPromoteTest` 3/3 (real
> post-GlobalOpt shapes; promotable/returned/passed-to-call) · smoke
> fixture `test/elm/src/AggPromoteTupleTest.elm` lowers AND RUNS flag-on
> with all 6 results correct incl. the mixed `(Int, String)` GC-pointer
> slot and tuple3 · full E2E flag-off **1609/1609** · flag-on corpus
> (tests touched) **1609/1609** · **second-order bootstrap gate: the
> flag-on-BUILT compiler's output is byte-identical to the
> flag-off-built compiler's on the same workload** · benchmark Run B
> (`benchmarks/borrow-inf-opt.md`).
> **Yardstick (honest):** flag-on self-compile promotes **40 sites**
> (39 t2 + 1 t3) of ~11,067 tuple constructs — 20× the old pass's
> 2/30,910 by count, far below the census's 31.8% lit:tup2 bracket, and
> dynamically ≈0 on self-compile (in-run A/B: −266 objects — the sites
> are cold). **The identified coverage lever (T1.3.1b): idiomatic
> `case t of (x, y) -> …` puts the tuple in CASE-SCRUTINEE position,
> which v1 conservatively rejects** — the census bracket lives there;
> emission-side decider paths already route aggregates, so the extension
> is walker + case-emission work, not new mechanism. Protocol note: ninja
> is env-blind — an env-only flavor rebuild must delete
> `bin/eco-compiler{,.mlir}` first (recorded in the benchmark file).

> **T1.3.1b AS-BUILT (2026-08-02): SHIPPED, all gates green — and the
> coverage hypothesis is CORRECTED.** Walker-only change (emission needed
> nothing: `generateCase` never touches the scrutinee var; decider paths
> already route dual-form; `Test.IsTuple` emits `constant true` ignoring
> the path value): a tracked tuple may be a case scrutinee iff the
> decision tree reaches it only through matching `DtIndex` projections,
> with the bare-root-under-`IsTuple` exemption and FanOut-dispatch
> required to project (`deciderScrutineeOk`/`dtTestPathOk`/
> `dtProjectingPathOk`). **Gates:** unit 6/6 (case-good, nested-pattern
> Chain test, case+call negative) · corpus fixture: 3 case shapes
> (incl. mixed-slot and nested `(0, y)` pattern) promote, lower, and RUN
> correctly · full E2E off **1609/1609** · flag-on corpus **1609/1609** ·
> second-order bootstrap byte-identity **PASS** · Run C recorded.
> **Yardstick: 40 → 43 sites (+3) — the hypothesis was wrong about
> where the mass is.** Two findings: (a) the pervasive
> `case ( a, b ) of …` idiom NEVER materializes a tuple — the DT
> compiler destructures literal-tuple scrutinees component-wise, so
> those "tuples" were never allocations; (b) the census's residual
> `lit:tup2` bracket (~31.8% of sites) is **call-boundary-entangled**:
> tuples passed to callees whose params the ORACLE proves
> borrowed/non-escaping — invisible to any per-def syntactic walk
> (T1-R1's boundary). **Conclusion: intra-def syntactic promotion
> saturates at ~43 sites / ≈0 dynamic effect on self-compile
> (−398 objects in-run A/B). The tier's dynamic payoff rides on
> T1.3.2 (ctor inlining localizes the Custom mass) and T1.3.3
> (call-boundary result ABI)** — the staging already points there;
> T1.3.1's machinery (walker + value emission + dual projections) is
> the substrate both consume.

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

> **AS-BUILT (2026-08-02): SHIPPED, all gates green — including a
> soundness hole found and fixed by the bootstrap gate.** Delivery
> deviates from the sketch below (both improvements): (1) customs have NO
> Mono construct node, so instead of MLIR-level inlining, **saturated
> single-ctor calls at let bindings are promoted directly to
> `eco.make.custom`** at the T1.3.1 hook — the call AND the allocation
> both vanish in one step; (2) NO separate case-of-known-ctor is needed
> for promoted candidates — safety falls out of the walker (multi-ctor
> consumers require tag dispatch on the root, which the T1.3.1b decider
> rules reject, so admitted candidates are projection-only single-ctor
> shapes; `MonoUnbox` field-0 unwraps admitted for custom kinds). As
> built: `Ctx.ctorBySpec` (SpecId→CtorShape, built in Backend) ·
> `promotableCtorCall` (saturation mirror of `generateCall`'s own
> criterion — **ctor calls carry `isSingleStageSaturated=False`**, so the
> staging flag alone rejects every ctor call; CallDirectFlat +
> non-function result is the real test) · `generateCustomCreateValue`
> (per-slot ABI coercion incl. unbox direction) · `Ops.ecoMakeCustom` +
> `ecoProjectCustomAgg` · dual-form dispatch in Patterns'
> `CustomContainer` AND `MonoUnbox` arms.
> **THE SOUNDNESS INCIDENT (load-bearing lesson):** the first cut passed
> units + fixture smoke but the flag-on BOOTSTRAP build failed —
> promoted customs leaked into `eco.box`/`eco.papCreate` operands. Root
> cause: **Elm let-siblings are mutually visible — an EARLIER sibling's
> closure RHS can capture a LATER binding (via the placeholder
> mechanism), and the escape walk only sees the candidate's
> body-suffix.** Fix: the chain-head guard — promote only when the
> incoming `ctx.currentLetSiblings` does not already list the name
> (ancestor chain ⇒ unseen earlier siblings). Conservative and lossy
> (yardstick 178 unsound → **91 sound**: 82 custom + 8 tup2 + 1 tup3;
> the tuple count dropped 42→8), and it retroactively hardened
> T1.3.1/1b, which had the same latent hole. Precise recovery (free-var
> scan of earlier siblings at the chain head) is recorded follow-up.
> **Gates:** unit 9/9 (ctor-good/escape-via-call/multi-ctor-reject) ·
> corpus fixture: 3 custom shapes incl. mixed-slot + Wrap/unbox run
> correct · full E2E off **1609/1609** · flag-on corpus **1609/1609** ·
> **flag-on bootstrap builds** (the gate that caught the bug) ·
> second-order byte-identity **PASS** · Run D: identical-workload A/B
> **−9 objects** — the 91 sites are cold on self-compile, consistent
> with B/C. The dynamic-payoff conclusion of T1.3.1b §above stands:
> intra-def syntactic promotion is now mechanism-complete for tuples AND
> customs, but self-compile dynamics need the call-boundary work
> (T1.3.3) and/or the precise sibling recovery.

> **T1.3.2p AS-BUILT (2026-08-02): precise recovery SHIPPED — and it
> re-diagnosed the incident.** Exploring the sibling recovery exposed
> the REAL leak mechanism: **`TailRec.compileLetStep` emits every
> loop-body let through a synthetic `MonoLet def MonoUnit`** (the real
> body is compiled separately via `compileStep`), so the escape walk saw
> an empty body and approved anything — 77 of the 87 guard-blocked
> sites, including every `solveGo` State. The conservative chain-head
> guard had suppressed these only by ACCIDENT (TailRec pre-installs
> `currentLetSiblings` containing the def's own name). As built:
> (1) **unit-body lets never promote** (the targeted fix);
> (2) the **per-chain forward-ref scan** — `generateLet` head-detects
> (first binder ∉ incoming siblings) and scans the `MonoLet` spine once
> for closure-mediated forward references (`occursAnyNames`: var uses,
> scrutinees, destructure roots, capture names) into
> `ctx.fwdRefdLetNames`, restored on chain exit; the hook AND the
> walker's alias sanction consult it — replacing the conservative
> guard (which also silently mis-handled `generateLetGroup`-routed
> chains). Yardstick **93 sites** (82 custom + 10 t2 + 1 t3; +2 genuine
> chain-interior tuples vs the guard), leak check **0**. Gates: unit
> 10/10 (incl. the returned-lambda capture fixture) · flag-on bootstrap
> **builds** · full E2E off + flag-on corpus **1609/1609** ·
> second-order **PASS** · Run E (−73 objects; walls tight).
> **THE NEXT COVERAGE ITEM IS NOW CONCRETE: thread the real body
> through TailRec's def-setup** (a Ctx field or an analysis-only
> wrapper) so the ~85 loop-body candidates — `solveGo` State et al.,
> the first plausibly HOT class — can be vetted by the same walker.

> **T1.3.2t AS-BUILT (2026-08-02): TailRec real-body threading SHIPPED
> — and the intra-def track is now CLOSED with a measured ceiling.**
> `Ctx.tailRecLetBody` carries the real loop-body suffix from
> `TailRec.compileLetStep` into the promotion hook (cleared in
> `ctxWithPlaceholders` so nested emission never misreads it); each
> compileLetStep position also unions the suffix forward-ref scan into
> `ctx.fwdRefdLetNames` (flowing down so position k sees refs from
> links 1..k-1), restored on step exit. Fixture proof: loop-LOCAL
> tuple and ctor candidates inside tail loops promote (make=1,
> heap-constructs=0 — a per-iteration allocation eliminated); the
> loop-CARRIED negative stays heap (make=0, constructs=1). Gates: unit
> 10/10 · flag-on bootstrap builds · full E2E off + flag-on corpus
> **1609/1609** · second-order **PASS** · leak check 0 · Run F.
> **The verdict the whole sub-track was building toward: yardstick
> 93 → 95 (+2).** The ~85 TailRec-class candidates are almost all
> loop-CARRIED — `solveGo`'s State flows into the next iteration's
> tail call — genuinely escaping under the current mechanism and
> correctly rejected. **The intra-def syntactic promotable population
> on this workload is ~95 sites, and every one is dynamically cold.
> The remaining candidate mass requires representation changes at
> boundaries: (a) aggregate-typed LOOP VARIABLES (scf.while/yield
> iter-args carrying `!eco.tuple2`/`!eco.custom` — the
> `Eco_AnyValueOrAggregate` widening on yields/joinpoint args already
> exists in the dialect; the work is TailRec loop-var typing +
> entry/exit bridging), which would unlock the solveGo State class —
> per-iteration allocations in the compiler's hottest loops; or
> (b) T1.3.3's call-boundary result ABI.** Those are the two levers
> left in this tier, in that order of expected value.

> **T1.3.3L AS-BUILT (2026-08-03): SCALAR-SPLIT loop variables SHIPPED
> (win-gated).** Lever (a) implemented NOT as aggregate-typed iter args
> (a loop-carried struct of GC pointers live across in-loop statepoints
> risks RS4GC's FCA-unimplemented path, and SROA does not split struct
> phis) but as **scalar splitting**: a selected tail-func param is
> carried as its per-field state slots (boxed field ⇒ own `!eco.value`
> col, unboxed ⇒ raw primitive) — zero new dialect surface.
> Mechanics: `TailRec.planParamGroups` (shape: tuple2/3 or
> single-ctor custom 2..6 fields — single-FIELD customs excluded,
> Can.Unbox has no container); flat `ParamGroup` state; entry = heap
> projections of the incoming boxed arg; body reads via
> `ctx.splitAggParams` (Patterns roots/Index/Unbox arms + a
> `generateMonoTest` constant fast path for IsTuple/IsCtor on split
> roots); whole-value use MATERIALIZES (constructs from slots — legal,
> Elm-immutable); tail args classify pass-through / promoted-aggregate
> (agg-project, SROA-folded) / fresh INLINE construct (elements compile
> straight into slots — the construct vanishes) / coerce+heap-project
> fallback. Split params' varMappings are REMOVED (bypass ⇒ loud
> `lookupVar` crash). Walker: bare tracked var at a shape-matching
> split position no longer escapes (`tailSplitOk`, scoped OUT of
> nested tail-def/closure bodies).
> **THE WIN GATE (the decisive design point):** ungated, 624 loops
> split but only 3 contained real wins — the rest paid eager per-slot
> heap projections (Dict.get's descent) and whole-use materialization
> (Dict.get's tuple KEY: `compare k key` would re-ALLOCATE per node).
> Ship rule: split ONLY if (a) `Expr.paramSplitAdmissible` (every body
> use is a projection — zero materializations possible) AND (b)
> `splitArgPolicy` (every tail arg at the position is pass-through or
> a fresh matching construct, ≥1 fresh = an allocation actually
> removed). Result on self-compile: **4 split loops, all pure wins**
> (partition-style accumulator pairs — per-iteration pair allocation
> gone; exit-time reconstruct only), everything else untouched.
> Fixture: tailCarried (carried tuple, make=1 construct=0), tailState
> (solveGo-shaped 3-field State, make=1 construct=0), tailTrack
> (inline ctor arg — Tk alloc vanishes entirely, boxed String slot),
> tailPeek (whole-use veto NEGATIVE, stays heap). solveGo itself is
> VETOED (its State has whole-value uses) — its loop-carried class
> needs T1.3.3's call ABI or helper-inlining first.
> **Yardstick note (measurement basis):** the 93/95 series is the
> SOLVER-engine leg; this step reproduces **95 = 82c+12t2+1t3
> exactly** (walker proven promotion-neutral; a subst-leg count is 90
> = 76c+13t2+1t3 — different mono graph, not a regression; forensic:
> gated == inert == 91-total on subst).
> Gates: unit 10/10 · flag-on bootstrap builds (twice) · full E2E off
> **1609/1609** · flag-on corpus **1609/1609** · aggregate-boundary
> leak scan 0 · second-order + Run G in `benchmarks/borrow-inf-opt.md`.

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

> **T1.3.2c AS-BUILT (2026-08-03): ctor-call inlining SHIPPED;
> case-of-known-constructor is a measured NO-GO.** Census-first (offline
> python over the solver-leg text MLIR): 51,480 static calls to 7,536
> ctor functions — but the case-of-known-ctor opportunity is EMPTY:
> **0 `eco.case` dispatches + 3 `get_tag` tests on locally-known ctor
> results in the entire self-compile** (the decision-tree compiler +
> shipped promotion leave no locally-visible known-ctor dispatch). Per
> census discipline the (B) rewrite is NOT built. (A) shipped at
> EMISSION altitude (the T1.3.2 as-built precedent, not MLIR-level):
> `tryCtorInline` at the head of `generateSaturatedCall` — both
> saturated-direct call kinds route there, so the criterion is inherited
> by construction — emits `eco.construct.custom` in the caller via
> `generateCustomCreateHeap`; slot preparation factored into
> `prepareCtorSlots`, shared with the make-form emitter so the heap and
> SSA forms cannot drift (CGEN_020/026; tag/bitmap/name identical to
> `Functions.generateCtor`). **NULLARY ctor calls are excluded** — they
> resolve to CAF-memoized/interned singletons (CGEN_068); a fresh
> construct would ADD allocation. Behind `ECO_CTOR_INLINE`
> (hash token `ctori`, default off), independent of `ECO_AGG_PROMOTE`
> for clean A/B. At scale: **42,539 saturated ctor-call sites → 0**;
> 8,941 nullary calls unchanged; yardstick 95 unchanged
> (promotion-neutral); boundary-leak 0. Gates: full E2E off
> **1609/1609** · flag-on corpus (aggp+ctori) **1609/1609** · flag-on
> bootstrap builds · second-order same-source **PASS** · Run H
> (wall 3:25.97, −1.03 s vs G on a larger workload —
> neutral-to-marginally-positive; no alloc-census leg: the transform
> relocates constructs, counts cannot move). **Remaining in this tier:
> T1.3.3 result ABI (also the solveGo-State unlock) and the default-on
> verdict for the whole flag family.**

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

**v1 selection (REVISED 2026-08-03 by the pre-work census below —
supersedes the original "leaf + directly-self-recursive, all sites
destructure" rule, which measured ~empty):** syntax-driven at Mono
altitude, zero cross-function coupling, two LOCAL facts only:
  1. **Callee side:** the returned tuple is **constructed in the
     function on every return path** (directly, or through the
     case/select joins already specced as old-plan Phase 3.4#1) — so
     the construct dissolves into Direct/sret scalars. Calls INSIDE
     the body are irrelevant to its result ABI: leaf-ness bought no
     soundness and excluded the entire hot class.
  2. **Call-site side: PER-SITE migration.** A destructuring site is
     rewritten to the promoted clone; every other site (and
     function-as-value uses) keeps calling the original — under the
     AbiCloning discipline the original IS the wrapper, so the
     all-sites requirement is unnecessary and brittle (one odd site
     must not veto `freshVar`'s 256 good ones). FORBID_OPT_003 (no
     CAF-slot sharing; singleton-REP lesson) applies to the clone.
What stays out on principle: closure-mediated calls (papExtend — no
per-callee ABI through dynamic dispatch; LSS fast-dispatch already
devirtualizes the provable singletons INTO the addressable set), and
worker→worker chaining (calls between promoted functions stay boxed at
that seam — optimizing it was the old fixpoint's job, and the measured
net-negative). `EcoFlattenAggBoundary` is recreated **only if**
param-side promotion later joins (results don't need it — sret/Direct
never put an aggregate type on the boundary). Validation instrument:
the 3.2-#2 post-RS4GC `-emit=llvm` FileCheck harness (salvaged idea,
small).

> **T1.3.3 AS-BUILT (2026-08-03): SHIPPED — the track's FIRST MEASURED
> WALL WIN: −5.9% same-source (−13.8 s), Tuple2 allocation −6.3%
> (−24.2M objects, −554 MiB).** Built with the census-revised selection.
> **C++ (the salvaged ABI, tag-free):** a MULTI-RESULT `func.func` IS
> the sret worker signal — `SretFuncOpLowering` (Stage-0, benefit 10)
> gives it the `(slot !llvm.ptr, args...) -> void` ABI; the
> multi-operand `eco.return` arm emits per-field GEP+stores immediately
> before return (CGEN_067 STRUCTURAL, re-ratified `enforced`); the
> multi-result `eco.call` arm allocas the slot in the caller's ENTRY
> block and reloads. v1 is SRET-ONLY (no Direct; all-primitive results
> use the slot too — the CGEN_064 cap evidence stands for a future
> Direct). Pinned by `test/codegen/value_sret_result_llvm.mlir`
> (statepoint-wrapped worker call, relocation-tracked reloads).
> **Elm:** `Backend.buildSretPromoted` (zero-capture funcs, tuple2/3
> result, every RESULT-spine leaf a tuple literal — spine = let/destruct
> bodies + case branches, MonoIf a recorded v1 cut — plus ≥1 let-bound
> direct site); `Functions.generateSretWorkerAndShim` (worker = real
> body compiled under `ctx.sretTailLayout`; original becomes a thin
> re-boxing shim); result-spine threading: tail tuple literals emit the
> make-form, spine cases get **DECOMPOSED YIELDS** — N scalar case
> results + one block-local `eco.make.*` rebuild after the merge
> (`emitSpineYield`/`finishSpineCase`), exactly the old pass's Phase
> 3.4#1 shape, REQUIRED because an aggregate case result becomes a
> struct block arg and trips RS4GC's FCA liveness assert (re-confirmed
> empirically); `Expr.trySretLetBinding` migrates sites PER-SITE (walker
> admission, multi-result call to `name$sret`, binder bound as scalar
> slots in `ctx.splitAggParams` — the T1.3.3L consumer machinery does
> the rest; no varMapping ⇒ loud crash on bypass). Behind
> `ECO_SRET_RESULTS` (hash `sretr`).
> **At scale (solver leg): 268 workers, 1,228 migrated sites —
> `Context.freshVar` 262/262**, plus the predicted state-threading class
> (rewriteMeta 36, allocId 20, freshR 16, …). Two gate-caught incidents:
> (1) TailRec synthetic-let slot bindings must PERSIST into the real
> loop body; (2) the FCA crash above + a tail-flag restore fix (the
> TupleCreate/If arms cleared the flag into their RESULT ctx, silently
> disabling yield decomposition downstream).
> **Gates:** unit 10/10 · full E2E off **1610/1610** · flag-on corpus
> (aggp+ctori+sretr) **1610/1610** · flag-on bootstrap builds ·
> second-order same-source **PASS** · boundary-leak 0 ·
> `ECO_INLINE_ALLOC=0` census A/B: Tuple2 385.1M → 360.8M · Run I
> (same-source A/B two pairs, equal majors). **Remaining in-tier:
> the default-on verdict for the flag family (the win now exists to
> justify it), Direct multi-return, MonoIf spines, and the solveGo
> re-attempt now that helper returns come back as scalars.**

> **T1.3.3 PRE-WORK CENSUS (2026-08-03, offline python over the
> solver-leg self-compile text MLIR — the selection-sizing pass):**
> universe = 12,944 tuple2/3-returning functions (978 record), but only
> **8,255 DIRECT call sites** reach them — the rest are
> closure-mediated (papExtend), out of ABI-cloning reach by design.
> **2,038 sites (25%) are destructure-only** — the addressable mass.
>
> | selection rule | funcs | sites |
> |---|---|---|
> | original v1: leaf-ish + local construct + all-sites-destructure | **10** | **38** |
> | strict-leaf variant | 2 | 4 |
> | drop leaf-ness (local-construct + all-sites) | 150 | 559 |
> | any producer shape, 100%-destructuring funcs | 490 | 1,714 |
> | per-site migration (every destructuring site) | — | **2,038** |
>
> The original rule captured **~0.5% of the addressable sites** — the
> intra-def lesson repeating (the timid subset of a hot class is
> empty). The top candidates are the **state-threading helper class**:
> `Context.freshVar` (**257 sites, all destructuring** — runs for every
> SSA name the MLIR generator mints), `Parse.Space.eat` (73),
> `Ops.ecoCallNamed` (39), `Specialize.specializeExpr` (37),
> `TypeSubst.unifyHelp` (37), `coerceResultToType` (29) — all
> `… -> ( a, state )` shapes, all excluded by leaf-ness, none needing
> it. Static census is now SUFFICIENT for selection design; the one
> remaining unknown is dynamic heat of the selected set, answered by
> the mandated `ECO_INLINE_ALLOC=0` A/B allocation census after
> landing (Tuple2 counts must visibly drop).

> **T1.3.3 EXTENSION CENSUS (2026-08-03; one-shot instrumented DEV-mode
> JS self-compile on the SUBST basis + offline python over its text
> MLIR; instrumentation removed after the run). Sized all four recorded
> extensions — three of four are NO-GO, and the solveGo question is
> answered structurally:**
>
> | extension | measurement | verdict |
> |---|---|---|
> | Direct multi-return | **1 of 266 workers** is all-primitive (`Numeric.divMod`, 1 migrated site); 265 workers / 960 migrated sites carry a boxed field | **NO-GO** — the state-threading class is inherently mixed (a boxed state in every result); registers would serve one cold site |
> | MonoIf spines | +22 funcs / **+62 sites** over the 645-strict / 266-called base; max 10 sites/func, no hot names | **NO-GO / park** — thin cold tail |
> | Tail-func tuple returners | 145 funcs / **335 let-bound sites** | largest remaining result-ABI slice; needs worker-izing loop results — moderate lift, unproven heat |
> | Record returners | 89 funcs / 231 sites | small; park behind tail-funcs |
>
> **The split-veto census (773 shape-eligible loop params rejected by the
> T1.3.3L win gate) re-answers the solveGo question:**
> - The hoped-for cheap unlock is EMPTY: **0 loops** flip by teaching
>   `splitArgPolicy` about sret-migrated call binders (none of the 21
>   admissible-but-policy-vetoed loops has one at a tail position).
> - The veto mass is **whole-value uses (752/773)**, of which **495
>   loops (64%) are argument-side only** (state passed bare into calls,
>   zero captures) — the param-side-promotion population, now sized.
> - **`solveGo` itself: `call:6, cap:20, tail:1` — the State is
>   CAPTURED twenty times** (the IO/continuation style). It is a
>   CLOSURE-class problem: neither param-side promotion nor helper
>   inlining unlocks it while 20 closures capture the state whole. Its
>   honest home is the tier-4 closure/borrow-facts track; it should stop
>   appearing as a near-term T1.3.x target.
>
> **Ordering consequence:** the near-term levers are (1) the default-on
> verdict (already justified by Run I) and (2) param-side promotion
> (CGEN_066 territory) with a measured population of 495 argument-side
> loops plus the census §18 call-boundary `lit:tup2` bracket; tail-func
> result workers (335 sites) are the only other slice worth carrying
> forward. Direct, MonoIf spines, and records are parked with numbers.

### T1.3.5 — Param-side promotion (`$psplit` workers; the call-boundary `lit:tup2` bracket)

**Status: SHIPPED 2026-08-03 (Run K).** As-built at scale (all-flags
self-compile): **28 `$psplit` workers / 281 migrated call sites**,
boundary-leak 0/68,579 signatures, fixture corpus 29/29 CHECKs, full
E2E 1611/1611, all-flags bootstrap EXIT=0 (after the backend
dead-chain fix — see the FCA addendum below), byte-identity PASS.
**Wall: neutral on the self-compile yardstick** (Run K 3:45.2 ≈ Run J
3:45.3, both −3.2/−3.3% vs off) — the static population is far
smaller than the census bracket suggested (most `lit:tup2`
call-boundary tuples flow to callees that fail projection-only or
free-slot admissibility). Census A/B appended to Run K.

**Original spec follows. The mirror of
T1.3.3: instead of results coming BACK as scalars, aggregate ARGUMENTS go
IN as scalars.** Measured population: the census §18 call-boundary
`lit:tup2` bracket (~31.8% of tuple sites — tuples built solely to be
passed to a callee that only projects them), plus 495 argument-side
loops as a *follow-on* (see "what this does NOT unlock" below).

**Zero C++.** Unlike sret, a param-split worker's signature is ordinary:
the promoted `!eco.value` param is replaced by N SCALAR params (unboxed
field ⇒ its ABI primitive, boxed field ⇒ its own `!eco.value`). No
aggregate type ever appears on any boundary, so CGEN_066's
post-condition ("no value-aggregate type at any func.func boundary")
holds BY CONSTRUCTION — `EcoFlattenAggBoundary` is not recreated; this
step *fulfills* the invariant rather than re-landing the pass. Existing
lowering handles multi-param scalar functions unchanged.

**Shapes:** tuple2/tuple3 (`Ctx.SplitTuple` + `Types.computeTupleLayout`)
and single-ctor customs with 2–6 fields (`Ctx.SplitCtor` +
`Types.computeCtorLayout`, single-FIELD customs excluded — Can.Unbox has
no container). Exactly `TailRec.planParamGroups`' shape rule; slot types
via `Types.tupleSlotTypes` / the ctor-field analog.

**Selection pre-pass — `Backend.buildPsplitPromoted : EcoConfig ->
Array (Maybe MonoNode) -> Dict SpecId PsplitInfo`** (wired at both
stream sites next to `buildSretPromoted`; `Ctx.psplitPromoted` +
`withPsplitPromoted`). `PsplitInfo = { paramPlans : List (Maybe
SlotPlan) }` with `SlotPlan = { spec : Ctx.SplitSpec, slotTypes : List
MlirType }` — one entry per ORIGINAL param position, `Nothing` for
unpromoted positions. A spec is promoted iff:
  1. it is a zero-capture `MonoDefine (MonoClosure …)` with ≥1 param
     (tail funcs excluded in v1 — their params interact with T1.3.3L's
     `planParamGroups`; recorded follow-on), and NOT sret-promoted
     (v1 mutual exclusion — a combined `$sret$psplit` worker is a
     recorded follow-on; overlap is rare since sret's customers return
     `(a, state)` while psplit's take container ARGS);
  2. ≥1 param position is shape-eligible AND
     `Expr.paramSplitAdmissible kind name body` (the EXACT T1.3.3L
     admissibility walk — every body use is a projection; any
     whole-value use, capture, return, or rebind vetoes, so worker
     bodies can NEVER materialize);
  3. the win pre-check: ≥1 direct call site in the graph where some
     eligible position's argument is *constructish* — an INLINE matching
     construct (tuple literal / saturated single-ctor call, the
     `isFreshConstruct` test against the position's SlotPlan) or a bare
     var let-bound to one in the enclosing body (a `scanSplitPolicy`-
     style binder-tracking scan). Without such a site the worker+shim
     pair is pure shim-hop overhead — the T1.3.3L win-gate lesson.

**Worker + shim emission — `Functions.generateClosureFuncSingle`**
(extend the existing `maybeSret` dispatch to a small sum:
`NoPromo | PromoSret SretInfo | PromoPsplit PsplitInfo`, threaded from
`generateNodeInner` via `Dict.get specId` on both tables; sret checked
first):
  - **Worker `name$psplit`:** signature = for each param, either its
    original `( "%name", abiTy )` pair or, if promoted, N slot pairs
    `( "%name_s0", slotTy0 ), …`. Body = the SAME body expr compiled
    with `ctx.splitAggParams` entries for each promoted param
    (`{ slots = the slot pairs, split = plan.spec }`) and the param's
    varMapping REMOVED — identical binding discipline to
    `TailRec.setupVarMappings` (bypass reads crash loudly in
    `lookupVar`; slot reads and the impossible-by-admissibility
    materialization path are the live T1.3.3L consumer machinery in
    `Patterns`). Result handling unchanged (single result, ordinary
    `eco.return`). No `sretTailLayout` is set.
  - **Shim `name` (original ABI kept):** for each promoted param,
    heap-project its N fields from the boxed argument
    (`Ops.ecoProjectTuple2/3` / `ecoProjectCustom` at slot stored
    types — the `TailRec.projectSlotsFromHeap` shape); direct
    `eco.call @name$psplit` with the flattened args; return its result.
    Function-as-value uses, closure dispatch, and unmigrated sites all
    keep working through the shim.

**Per-site migration — `Expr.tryPsplitCall`, dispatched at the head of
`generateSaturatedCall` beside `tryCtorInline`** (both saturated-direct
call kinds inherit the criterion). A site migrates iff the callee is
promoted AND **every** promoted position's argument is slot-available
FOR FREE — the T1.3.3L rule that forbids eager heap-projection
migration (a loss, never a win):
  - **inline matching construct** → compile the elements straight into
    the slot args (the `TailRec.inlineConstructSlots` pattern; the
    container never exists — the pure win, no walker involvement);
  - **bare var with a `ctx.splitAggParams` entry** whose slot types
    match the plan → pass its slot vars (zero ops; covers split loop
    params, sret-migrated binders, and worker params);
  - **bare var whose context type is the matching AGGREGATE** (a
    make-promoted candidate) → `Ops.ecoProjectTuple2/3Agg` /
    `ecoProjectCustomAgg` per slot (folded by SROA — free);
  - anything else at any promoted position ⇒ NO migration; the site
    calls the shim unchanged. Unpromoted positions compile exactly as
    the plain path does (`boxToMatchSignatureTyped` against the
    callee's signature).

**Walker allowance (the candidate side of the bracket) —
`Expr.walkPromo`'s `MonoCall` arm.** Today a tracked candidate passed
to ANY call is rejected. New rule, mirroring `tailSplitOk`: a BARE
tracked var at argument position i of a direct call
`MonoCall _ (MonoVarGlobal _ sid _) args …` is admitted iff
`psplitOkPositions` grants (sid, i) — precomputed per candidate KIND as
`Dict SpecId (Set Int)` (positions whose SlotPlan shape-matches the
kind), built by a `tailSplitAllowSet`-style helper from
`ctx.psplitPromoted` at the walker entry points. Same scoping rule as
`tailSplitOk`: cleared for nested tail-def and closure bodies. The
emission then agrees by construction: an admitted candidate is
make-form, so `tryPsplitCall`'s aggregate arm slot-projects it; if the
site nevertheless fails migration (another position not free), the
aggregate coerces through `boxToEcoValue`'s `eco.to_heap` arm at the
shim boundary — sound, allocation identical to today (coercion-
soundness, the T1.3.3L pattern).

**What this does NOT unlock (honest scope, from the split-veto
census):** the 495 argument-side loops need BOTH this step (fixing
their admissibility via a `paramSplitAdmissible` allowance for
psplit-migratable call positions — include that allowance, it is the
same `psplitOkPositions` check) AND their tail-arg policy, which mostly
fails on `let s2 = helper state in loop s2` shapes where `helper`
returns a CUSTOM state — outside sret v1 (tuples only). Loop-count
gains here are therefore expected ≈0 until sret covers custom results;
record the measured count, do not promise it. `solveGo` stays a
tier-4 closure problem regardless (cap:20).

**Flag:** `ECO_PSPLIT_PARAMS`, hash token `psplit`, default off,
independent for A/B. **Fixtures:** extend
`test/elm/src/AggPromoteTupleTest.elm`: a projection-only pair consumer
called with (a) an inline literal (the container must vanish), (b) a
previously-vetoed let-bound candidate (now promotes + migrates), (c) a
whole-use consumer NEGATIVE (no worker), (d) a mixed-position partial
NEGATIVE (site calls shim); single-ctor custom variants of (a)/(b).
**Yardstick:** `$psplit` workers + migrated sites + boundary-leak scan
(unchanged: no aggregate may appear in any `function_type`).
**Gates:** the standard battery + `ECO_INLINE_ALLOC=0` census A/B
(Tuple2 AND Custom must drop — this transform removes both) + Run K
same-source wall pairs.

**AS-BUILT ADDENDUM — the K-bootstrap FCA crash (found + fixed
2026-08-03, backend-side).** The first all-flags K bootstrap aborted in
`RewriteStatepointsForGC` ("support for FCA unimplemented",
`computeLiveInValues`). Forensics that mattered:

- **Two false trails burned a day**: (1) grepping `ecoc` output for
  "FCA\|Assertion" matched the *compiler's own string literals* in the
  526MB LLVM dump (ecoc's `-emit` dumps IR to the stream being
  grepped) — judge lowering repros by **exit code only**; (2)
  `ecoc -emit=llvm` was "clean" on the crashing artifact because its
  `DumpLLVMText` job defaults `optLevel=None`, which **skips
  `runCapInlinePrepass`** — only `eco-boot-native -o exe` (optLevel 2)
  reproduced. Both drivers share `runEcoBackend`; the divergence was
  the `$cap` prepass gate, nothing else.
- **Root cause**: `emitPsplitSlotArg`'s aggregate-var arm plants
  `eco.make` + projections at call sites inside tiny `$cap` closure
  wrappers (e.g. `Terminal_Main_lambda_22642$cap`). The pre-RS4GC
  `$cap` AlwaysInliner folds the extracts *while cloning*
  (`InlineFunction`'s `SimplifyInstruction` — the file's own comment
  already recorded "standalone bodies never fold; InlineFunction's
  SimplifyInstruction does"), RAUWs the fields into the `$psplit`
  call, and leaves the cloned insertvalue chain **dead**.
  `FoldExtractValuePass` iterated only `ExtractValueInst`s, so a chain
  with no extracts left was never deleted — and RS4GC asserts on the
  dead chain's own aggregate operands (it walks all instructions,
  live or not). 10 survivors in 2 functions in the whole bootstrap.
- **Fix** (`runtime/src/codegen/Passes/EcoPtrIntVerify.cpp`): after
  the extract-folding loop, sweep trivially-dead `InsertValueInst`
  chain heads (`WeakTrackingVH` worklist +
  `RecursivelyDeleteTriviallyDeadInstructions`). Deletion-only ⇒
  flag-off IR untouched (byte-identity holds).
- **Permanent forensic tool**: `FcaScanPass` (same file), env-gated
  `ECO_FCA_SCAN=1`, runs between the fold and RS4GC and reports every
  surviving aggregate-with-gc-pointer instruction with
  function/block/instruction context, then hard-errors — turns the
  bare LLVM assert into a named diagnosis.
- **Regression fixture**: `test/codegen/value_dead_agg_chain_llvm.mlir`
  — true-to-life `$cap` wrapper (make + projections + allocating
  consumer) called directly; `%ecoc -emit=llvm -opt` runs the inliner
  prepass, orphans the chain, and the sweep must clean it (verified
  firing via `ECO_CAP_INLINE_DEBUG` + `ECO_FCA_SCAN`).

### T1.3.6 — Tail-func result workers (widening `sretr` to loop returns)

**Status: BUILT, MEASURED REGRESSION → DEFAULT-OFF (2026-08-03, Run
J isolation A/B).** The widening works (68 tail-func `$sret` workers
at scale, 336 total vs 268; fixtures `tailpair`/`tailboth` pass) but
costs **~+4% wall — it cancelled T1.3.3's −4% almost exactly**,
which a 2-arm A/B could not see (J-with-widening ≈ off for a full
9-leg session; only the 3-arm `ECO_SRET_TAILFUNC` isolation exposed
the cancellation). Mechanism: the N result-slot columns are
loop-carried through EVERY iteration of the while (dummy values until
the exit iteration) — per-iteration register/carry cost in hot solver
loops swamps the once-per-call container saving. Exactly the spec's
pre-registered risk ("the 335-site heat is unproven — if the A/B is
flat, record the ceiling and keep the machinery"); outcome one worse
than flat. **Shipped state: `Config.sretTailFuncs` default FALSE,
opt-in `ECO_SRET_TAILFUNC=1` (hash token "srtf=1" when enabled),
machinery kept** — it is the substrate for any future custom-result
sret and for revisiting with an exit-block-only result materialization
(the obvious fix shape: keep results OUT of the loop-carried state and
materialize in the after-region from the final state — recorded here
as the revive condition).

**Original spec follows (census: 145 funcs / 335
let-bound sites — the largest remaining result-ABI slice).** A
tail-recursive function returning a locally-constructed tuple2/3
allocates its result container once per CALL at loop exit; the migrated
call sites then re-project it. Same win shape as T1.3.3, same flag
(`sretr` — this is selection widening, the T1.3.1b precedent), same
call-site machinery (`trySretLetBinding` keys on SpecId and needs no
change).

**Selection — extend `Backend.buildSretPromoted`** to also accept
`MonoTailFunc params body monoType` nodes where:
  1. `closureResultType monoType` is `MTuple` 2/3;
  2. every RESULT leaf of the body constructs: a `sretTailOk`-style walk
     over the *step* shape — `MonoTailCall … -> True` (a loop continue,
     not a result), `MonoTupleCreate` arity-match -> True,
     `MonoLet/MonoDestruct` bodies + `MonoCase` branches + **`MonoIf`
     branches** recurse (MonoIf IS admissible here — TailRec's
     `compileIfStep` compiles branches via `compileStep`, so the
     result-spine flag threads through it, unlike Expr's `generateIf`);
     any other leaf -> False. NOTE the Expr-side `sretTailOk` is NOT
     reused directly (it lacks the TailCall arm and admits nothing
     if-shaped): add `sretTailFuncOk` beside it;
  3. ≥1 let-bound direct call site (the existing `collectSretSites`
     scan already covers calls to tail funcs — only the candidate
     collection needs the new node arm).

**Emission — the result column of the while becomes N slot columns.**
This is the one structural change, in `TailRec`:
  - `compileTailFuncToWhile` gains `resultPlan : Maybe Ctx.SretInfo`
    (threaded from `Functions.generateTailFunc`, which receives
    `maybeSret` from `generateNodeInner` exactly as `generateDefine`
    does; `Lambdas`' tail-rec branch passes `Nothing` — local tail
    lambdas are NOT nodes and are out of scope v1).
  - `StepResult.resultVar/resultType` become `results : List ( String,
    MlirType )` (singleton `[ ( v, retTy ) ]` when unpromoted — keep
    every existing call shape working by construction). Mechanical
    touch points: `checkedYieldOperands` (expected = paramTypes ++ [I1]
    ++ resultSlotTypes), the `numParams + 2` arithmetic in
    `compileCaseChainStep`/`compileCaseFanOutStep`/`compileIfStep`
    (`+ 1 + slotCount`), `compileTailCallStep`'s dummy result
    (`createDummyValue` per slot type), `buildBeforeRegion`/
    `buildAfterRegion` state widths, and the final result extraction
    (last N columns instead of last 1).
  - **Base-return steps** (`compileBaseReturnStep`): compile the base
    expr with `ctx.sretTailLayout = Just layout` — the ENTIRE T1.3.3
    result-spine machinery (make-form tail literals, decomposed case
    yields, `from_heap` fallback) applies verbatim inside the loop —
    then coerce to the aggregate and project the N slots
    (`ecoProjectTuple2/3Agg`) as the step's `results`. Nothing new is
    invented; the aggregate stays block-local (the FCA rule).
  - **Worker/shim:** the promoted tail func emits as
    `funcFuncMulti (name ++ "$sret")` whose terminal is
    `eco.return`-multi of the while's N result columns (the C++ sret
    lowering from T1.3.3 handles the rest untouched), plus the standard
    re-boxing shim under the original name. Interaction with T1.3.3L:
    param splitting (`planParamGroups`) composes — state columns are
    param-groups ++ done ++ result-slots.

**Fixtures:** a tail-recursive `( acc1, acc2 )` builder (double
accumulator — base case returns the pair) with a destructuring caller:
flag-on the worker's loop must contain NO tuple construct (make-form +
slot columns only) and the migrated site consumes slots; a
loop-carried-param + promoted-result combination (T1.3.3L + T1.3.6 in
one function) pinning composition. **Gates:** standard battery; the
alloc-census delta rides the same Tuple2 counter; Run J same-source
pairs. The 335-site heat is unproven — if the A/B is flat, record the
ceiling and keep the machinery (it also serves psplit's follow-on).

### T1.3.7 — psplit rejection-reason census → selection self-fixpoint (expected-value #1)

**Status: SHIPPED 2026-08-04 (Run L). AS-BUILT SUMMARY — mechanism
proven, population honest-small.** Census A (DEV-JS, subst leg):
adm-params 1,027 / passthrough-only 1,176 / other 1,629 /
probe-new-fns 941 / **candidates 982 vs justified 27** — the decision
rule passed on justification-only dominance. Phase B shipped three
pieces: (1) the selection fixpoint as specced (`psplitFixpoint` /
`psplitOnePass`, round N−1's FILTERED table = walker allowance + scan
seed; monotone in both uses so the table only grows — iterating on the
filtered table, not raw candidates, is what makes the fixpoint
self-consistent with emission, so no admitted pass-through ever
rematerializes); (2) a **pre-order site scan** (`psplitScanExpr`)
replacing the `MonoTraverse.foldExpr` driver — **latent v1 bug found:
foldExpr is BOTTOM-UP, so binder shapes were registered after the call
sites that needed them; the binder-justification channel was dead from
day one**, masked by inline-construct sites; (3) beyond spec, the
**sret→psplit nested composition**: `psplitArgFree`/`emitPsplitSlotArg`
accept an arg that IS a direct sret-promoted call (slot-type-exact) and
emit the multi-result `$sret` call feeding scalars straight into the
`$psplit` worker (`emitSretCallMulti` factored and shared with
`emitSretLetBinding`) — fixture emits `(i64,i64)` end-to-end with no
container. At scale: **34 workers / 294 sites (+6/+13 over v1)**;
census −27.55M objects ≈ Run K (+60K from the delta); wall −2.9% ≈
ship config; all gates green (E2E 1611/1611, corpus 35 CHECKs incl.
`psplitchain`/`psplitsret`/`psplitneg`, byte-identity, leaks 0,
all-flags bootstrap). **LESSON RECORDED: the census's admissibility
buckets are upper bounds on a DIFFERENT gate — justification is
bounded by upstream slot-form availability (closure/record/kernel
producers), not by analysis precision; the remaining 950-odd
candidates wait on upstream promotion classes (T1.3.4/T1.3.8), and no
selection-side cleverness reaches them.**

**Original spec follows (from the borrow-facts exploration — the
five-agent review of what an oracle could lift; verdict: the liftable
class is oracle-FREE).** v1 psplit reached only 28 workers / 281 sites
from a ~31.8% census bracket because selection runs
`paramSplitAdmissible Dict.empty …` — the admissibility walk's
`callSplitOk` allowance table (which `walkPromo` already consults for
pass-through call args) is NEVER POPULATED at selection time, so zero
transitivity: a param forwarded to another projection-only callee
vetoes both. Additionally `psplitSiteScan` justification accepts only
inline-construct / locally-let-bound-construct args — it does not
recognize sret-migrated call-result binders even though EMISSION
already accepts them (`emitSretLetBinding` persists `splitAggParams`
bindings that `psplitArgFree` consumes).

**Phase A — census first (the standing discipline).** DEV-mode JS
eco-boot build (native `--optimize` forbids Debug.log); instrument
`planForParam`/`walkPromo` to bucket every veto: (1) whole-use-owned
(return/store/element/capture), (2) pass-through-to-DIRECT-callee
(the self-fixpoint class), (3) kernel-read (`compare`-class — NOT
liftable, rematerialization loss), (4) non-projection decider, (5)
candidate-ok-but-justification-only (the sret-binder class). One
self-compile run; CENSUS-TEMP markers; remove after. **Decision
rule: proceed to Phase B iff buckets (2)+(5) dominate the veto mass.**

**Phase B — two oracle-free widenings (zero C++, est. 1–2 days).**
(a) Selection self-fixpoint: iterate `buildPsplitPromoted` passing
round-(n−1) candidates as the `callSplitOk` allowance until the
candidate set is stable (monotone-increasing table; expect 2–3
rounds, same traversal class as `buildSretPromoted`, ≪1% wall — vs
the borrow pass's ~15% T1-R1 toll this replaces). (b) Teach
`psplitSiteScan` the sret-binder and forwarded-chain justification
shapes emission already handles. **Gates:** standard battery +
`ECO_INLINE_ALLOC=0` census pair re-run (expected: workers 28 → low
hundreds; Tuple2 drop beyond Run K's −6.33%; wall likely still
neutral — record honestly either way). Same flag (`psplit`); the
fixpoint is selection-internal, no new config surface.

### T1.3.8 — Result-freshness summary → custom/helper-mediated sret (expected-value #2)

**Status: CONSUMER 1 SHIPPED, CONSUMER 2 (CUSTOM) DEFERRED BY CENSUS
2026-08-04 (Run M).** Census A (DEV-JS): helper-mediated TUPLE class =
**5 fns / 11 sites** (near-empty — the freshness summary was built as
the pre-registered fixpoint form, not a separate pass); CUSTOM class =
**32 fns / 238 static sites** — far below what the track's largest
emission surface (SretInfo generalization, custom spine machinery,
custom decomposed yields, TailRec custom columns) would need to pay
for itself; **deferred with numbers recorded, revive condition =
dynamic evidence that the 238 sites are hot** (a dynamic per-site
census, not more static counting). As-built for consumer 1:
`Config.sretFresh` (`ECO_SRET_FRESH`, hash "sretf=1", default OFF);
`sretFreshFixpoint`/`sretFreshTailOk` in Backend (leaf = direct call
to a table member with IDENTICAL slot types; site-gated filtered-table
iteration — the T1.3.7 discipline); `trySretFreshLeaf` in Expr (spine
MonoCall leaf → `emitSretCallMulti` + make-form rebuild; consulted via
the pre-hygiene ctx so dispatch clearing is unaffected; UNREACHABLE
flag-off by construction since legacy selection rejects call leaves —
no emission gate needed). At scale: 273 workers (+5, census-exact),
leaks 0/68,570; 3-arm isolated Run M: **ship+sretf ≡ ship** (neutral,
no cancellation); fixtures `sretfresh`/`sretmix`/`sretnegv`; E2E
1611/1611. **The tier-wide pattern is now confirmed three times
(psplit bracket, T1.3.7 justification, T1.3.8 helpers): static census
brackets collapse at the admissibility/win gates — remaining tier-1
upside lives in DYNAMIC evidence and upstream representation classes
(closures/records), not in more selection precision.**

**Original spec follows (2026-08-04).** The highest-value
sret widening — helper-mediated construction (`let s2 = helper state`)
and CUSTOM results — is gated on one derived fact: **"callee's result
is freshly constructed and aliases no param."** That fact needs no
borrow oracle: build a bottom-up result-freshness summary over the
mono graph — leaf = local construct ⇒ fresh; leaf = direct call ⇒
callee's summary (SCC fixpoint, same shape as the sig fixpoint);
kernel leaf ⇒ `KernelSigs.resultAliases == []` (the result-flow fact
that already exists as static data); anything else ⇒ not-fresh.
O(defs), runs beside `buildSretPromoted`, no standing toll.

**Consumers, in order:** (1) widen `buildSretPromoted` leaf
admission from "syntactically local `MonoTupleCreate`" to "leaf is a
call whose summary says fresh tuple2/3" (slot-type-exact still
applies); (2) CUSTOM-result sret — single-ctor customs 2–6 fields
(reuse `Ctx.SplitCtor`/`ctorSlotTypes` from psplit; worker returns
tag-free known-ctor slots) — this is the recorded gate on the **495
argument-side loops** (their `let s2 = helper state in loop s2`
helpers return customs) and rides the 9.0%-weighted `call:custom`
class. **Discipline:** new flag (suggest `ECO_SRET_FRESH`, hash
token `sretf`), census-first sizing of how many helpers the summary
proves fresh BEFORE building emission; fixtures for helper-mediated
tuple, helper-mediated custom, and a NEGATIVE (helper returns a
param — summary must say not-fresh). Gates: standard battery + Run-L
same-source pairs. Risk note: this grows worker count — watch for a
T1.3.6-style cancellation; benchmark this flag ISOLATED (3-arm: off /
prior-ship / +sretf), never only paired.

### T1.3.9 — T1.3.6 revival: param-column aliasing (expected-value #3)

**Status: CENSUS NO-GO 2026-08-04 — (a) NOT BUILT; widening stays
default-off.** The accumulator-shape census (DEV-JS, sretr+srtf leg;
strict criterion = every base leaf a verbatim `MonoTupleCreate` of
loop params, consistent across leaves) measured **2 of 432
admitted-worker events (0.5%) alias-eligible** — the `tailpair`
fixture class is essentially absent from the real population. Real
tail-func workers return COMPUTED results (`( result, finalState )`
with let-bound computation), which is exactly why the result columns
exist and why the widening regressed; param-column aliasing has
nothing to alias. Ladder outcome: (a) dead; the standing revive
conditions are **(b) cf-level exit-edge materialization** (block args
on the exiting branch — scf.while cannot express exit-only values; a
real emission rework, unscheduled) **or a heat-gated selection from
dynamic profile data**. Fourth instance of the tier pattern: the
fixture-class shape did not represent the population — census before
machinery, every time.

**Original spec follows (T1.3.6 stays
default-off until (b) or heat gating lands and re-measures).** The +4% regression
is mechanical: result slots are loop-carried scf.while state
(`stateTypes = flatParamTypes ++ [I1] ++ resultSlots`), with fresh
dummies minted per continue (`compileTailCallStep`) and all columns
forwarded through `scf.condition` every iteration — extra gc-live
entries + relocations at every in-loop statepoint, paid per
iteration for a once-per-call saving.

**The fix, cheapest first:** (a) **param-column aliasing** — when a
base step yields param columns verbatim (the accumulator shape
`(acc1, acc2)`, fixture class `tailpair`, likely the majority of the
68 workers): emit NO result columns at all; the exit extraction
reads the param columns directly. Zero extra carried state, zero
dummies — the accumulator class becomes free by construction. (b)
Workers with non-param results keep columns v1-style; if (a) alone
doesn't clear the regression, the follow-on is cf-level exit-edge
materialization (block args on the exiting branch — scf.while cannot
express exit-only values), a bigger emission rework recorded here as
the fallback, NOT scheduled. (c) A heat gate (profile data) only if
hot non-accumulator workers remain — borrow facts explicitly ruled
out as the discriminator (they'd only WIDEN selection and anti-help).
**Measure:** census the accumulator-shape share of the 68 first;
implement (a); re-run the 3-arm isolation (off / ship /
ship+`ECO_SRET_TAILFUNC=1`). **Decision rule: widening flips
default-on only if the isolated arm shows ≤0% wall vs ship AND the
alloc census still shows the Tuple2 drop.**

### T1.3.4 — Closures: deferred (recorded, not scheduled)

`lit:clo`/`call:clo` (5.6% weighted) stay out: closure envs were 89% of
the old rejection mass, the capture-ABI surface (`$cap`/`$clo`,
REP_CLOSURE_*) is the riskiest in the backend, and the honest path runs
through borrow-facts export (tier 4 / U-T1.4). The old plan's Phase-4
plumbing (`closure_env` type + ops + lowering) stays warm in-tree.

> **ORDERING DECISION (2026-08-03): considered for promotion ahead of
> T1.3.3 — stays parked.** The T1.3.3 census surfaced that most
> tuple-returning FUNCTIONS are closure-mediated, which raises the
> question; the answer is no, for four reasons. (1) T1.3.4-as-scoped is
> closure-ENV promotion, not per-callee call ABI — doing it first would
> not make closure-mediated tuple returns addressable (true dynamic
> dispatch cannot carry per-callee scalar ABIs; the devirtualizable
> cases are already direct via LSS fast-dispatch and already inside
> T1.3.3's 8,255-site universe). (2) T1.3.3 is unblocked TODAY on a
> fully-worked salvaged spec; T1.3.4's honest path needs borrow-facts
> export — tier-4 machinery that does not exist and carries the T1-R1
> ~15%-toll problem. (3) Comparable weighted mass (5.6% vs 6.8%) on the
> riskiest backend surface vs a spec that "was never the failing part".
> (4) The old program's own evidence: closures were 89% of its
> rejection mass — the class most resistant to exactly this analysis.

### Order & expected yield

`0 → 1 → 2 → 3` (4 parked). Step 1 alone targets the ~6% intra-def
`lit:` slice; step 2 opens the 9.0%-weighted `call:custom` class; step 3
the 6.8%-weighted `call:tup2` class (census §18.4). Steps are
independently shippable and independently measurable; each failure mode
(harness rot, predicate coverage, inline seams, statepoint discipline)
is isolated to the step that owns it.

**DEFAULT-ON VERDICT (decided 2026-08-04): the family stays
DEFAULT-OFF.** All six flags (`aggp`, `ctori`, `sretr`, `psplit`,
`sretf`, `srtf`) remain opt-in via env. Verification snapshot at the
decision: family-on full E2E 1611/1611 (family-built compiler +
family-compiled corpus, test caches touched for the env-blind-harness
trap); solver+LSS+family bootstrap EXIT=0; the srtf widening excluded
from the verification config by its measured-regression decision.
Revisit trigger: dynamic per-site heat evidence or the tier-2 work
changing the economics.

**Follow-on order (2026-08-04, post-Runs-J/K):** `7 → 8 → 9` in
expected-value order from the borrow-facts exploration — T1.3.7
(psplit rejection census → self-fixpoint, cheapest, census-gated),
T1.3.8 (result-freshness summary → custom/helper sret, the 495-loop
gate), T1.3.9 (T1.3.6 revival via param-column aliasing; widening
stays default-off until its isolated re-measure clears ≤0% wall).
All three are deliberately oracle-free (T1-R1); the oracle's real
consumers remain T1.3.4/U-T1.4.

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
