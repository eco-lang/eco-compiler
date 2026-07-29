# Borrow Inference — Phase 1.5: The Analysis-Oracle Track (Strategy B)

**Status:** TRACK / COORDINATION plan. This is **not** a new implementation
spec — it is the umbrella that ties the analysis-half milestones together
under one owner, adds the cross-cutting concerns that live in no single
phase plan, and records the scope decision (Strategy B) and its exit gate.

**Parent design:** `design_docs/globalopt/borrow-inference-design.md` (v2),
§22.1 (the A/B/C runtime-strategy call). **Evidence base:**
`design_docs/borrow-inf-census.md` (the Phase-0 / B0 report — this track's G1 gate).

**Relationship to the per-phase plans (READ FIRST):** this plan
**coordinates, it does not supersede**. The implementation detail for each
milestone stays in its owning plan and those remain the
IMPLEMENTATION-READY specs:

| milestone | owning plan (the spec) | in this track? |
|---|---|---|
| B0 | `borrow-inference-phase0-measurement.md` | ✅ done |
| B1 | `borrow-inference-phase1-foundations.md` | ✅ |
| B2 | `borrow-inference-phase2-intradef-analysis.md` | ✅ |
| B3 | `borrow-inference-phase3-interprocedural.md` | ✅ |
| B3.5 | `borrow-inference-phase4-lss-handshake.md` | ✅ |
| B4 / B5 | `borrow-inference-phase5-rc-optimizations.md` | ❌ **out of scope** |
| B6 | `borrow-inference-phase6-v2-backlog.md` | ❌ (decision register) |

Do not fork or re-number those plans. This document adds the *track-level*
layer above them; drop into the phase plans for how each milestone is built.

> **Why "1.5"?** The number is a coordination label, not a milestone
> index — this plan follows B1 (the last plan with no cross-milestone
> concerns) and consolidates the analysis track B0→B3.5 that begins in
> earnest at B2. It is the plan you hand to whoever drives the analysis
> track end to end.

---

## 1. Why this plan exists

Strategy B (build the borrow **analysis** and stop before the RC
**runtime** track) is a single coherent deliverable — a shipped,
inert-by-construction uniqueness/sharing **oracle** plus its census — but
it is currently spread across five plan files, and three of its defining
properties are written down nowhere:

1. **The inert-oracle shipping posture** — the terminal state of this
   track is a pass that runs on every build and emits **zero** IR changes
   (`reify = ROff`); no phase plan owns "this is where the program stops
   and what that shipped state looks like."
2. **The oracle-consumer surface** — the whole value of B without RC ops is
   that the facts are *consumable*; no phase plan enumerates who reads them.
3. **The exit / escalation gate** — when B is "done," and the trigger that
   re-opens Strategy A (the RC runtime) / v2. §22.1 + D0.6 leave this as a
   preliminary call; this plan is where it is recorded and re-taken.

This plan owns those three, plus the cross-cutting verification and
sequencing that apply to *every* analysis milestone.

---

## 2. The Strategy-B scope decision

**Decision (preliminary, B2-revisited per D0.6):** implement the analysis
half — **B0 → B3.5** — and ship it as a standing inert oracle. **Do not**
implement the reification / RC-runtime track (B4/B5) in this program.

**The scope boundary is the `phase4`/`phase5` file seam** — a clean cut, by
design: everything ≤ B3.5 is pure analysis over the Mono graph; B4 is the
first milestone that emits IR and touches the runtime. Nothing is
half-implemented at the boundary.

**Evidence** (`design_docs/borrow-inf-census.md`, self-compile, solver/all-keyed):

| lens | v1 pointer-free-buffer surface | the rest |
|---|---:|---|
| static occurrences | strings **6.9%** | closures 42%, customs 34%, lists 11%, records 6% |
| runtime self-time (perf) | buffer-family **4.2%** | GC **~29%**, closure dispatch 13%, mutator ~49% |
| allocation volume | string leaves **0.05%** (432K / 798M objs) | Cons/closure/tuple-dominated, 19.9% promoted |

Compounded with the Phase-5 fact that **v1 `rcManaged` has no RC-1
in-place-mutation targets** (its buffer kernels are purely functional), the
runtime track's only v1 lever is old-gen reclaim of a 0.05%-of-allocations
surface — an upside-down cost/payoff for the large, correctness-critical
B4/B5 runtime commitment. The analysis, by contrast, is cheap,
graph-inert, engine-independent, and the prerequisite for the version that
*does* pay (v2 arrays/lists). Hence: build the analysis, defer the runtime.

This is **not "no" to RC** — it is "not yet," with an explicit trigger (§7).

---

## 3. The consolidated deliverable: an inert oracle + census

The terminal state of this track is a GlobalOpt **Phase-6** pass that, on
every compile:

- runs the full per-def + interprocedural borrow analysis, and
- returns the `MonoGraph` **unchanged** (`reify = ROff`) — emitting **no**
  RC ops, so the produced MLIR is **byte-identical** to a build with the
  pass off, and the pass is **hash-inert** (excluded from `Config.hash`,
  exactly like the Phase-0 census and `mono.validate`).

Its outputs are **facts, not code changes**:
1. a per-`SpecId` / per-resource **uniqueness–sharing–lifetime oracle**
   (Stage A–D solver readback: `reifiedMode`, `ltAOf`, `coercionPoints`,
   plus the B3 `BorrowSig`s), and
2. the **`BorrowStats` census** (design §13) — the single source of truth
   that sizes every downstream/v2 decision.

This posture is identical to the Phase-0 census I already shipped
(`ECO_BORROW_CENSUS0`): present, always-run, provably output-neutral. The
Phase-0 census is the throwaway precursor; B2 replaces it with the real
per-def analysis and the flag/field are deleted then.

### T-DECISION-1 — shipped default posture

Ship `borrow.enabled = True, borrow.reify = ROff` **as the default** iff
the cumulative wall cost of the always-run analysis clears the track wall
gate (§6, ≤3% over B2+B3+B3.5 interleaved self-compile). If it does not,
ship **off by default**, run under `ECO_BORROW=1`, and surface the census
under `ECO_BORROW_REPORT=1`. Record the measured wall in this plan's
as-built section at B3.5. (Rationale: an always-inert oracle is only worth
defaulting on if downstream consumers or standing census value justify the
per-build analysis cost; until a consumer lands, off-by-default + report
flag captures the census value at zero standing cost.)

---

## 4. Milestone roadmap (acceptance gates; specs live in the phase plans)

One-line scope + the acceptance gate per milestone. Full construction
detail is in the owning plan (§0 table). Dependency order in §5.

- **B0 — measurement (DONE).** `borrow-inference-phase0-measurement.md`.
  Gate ✅: E2E 1636/1636, census byte-identical on/off, ceiling recorded in
  `design_docs/borrow-inf-census.md`, U0.5 header-preservation assertion scaffolded
  (all three nursery copiers).

- **B1 — foundations.** `borrow-inference-phase1-foundations.md`.
  Deliver `Borrow/Lifetime.elm` (lattice) + `Borrow/Dsu.elm` (union-find),
  leaf modules, no pipeline wiring.
  **Gate:** `elm-tests` green incl. the exhaustive lattice battery + DSU
  laws (dev-loop `--fuzz 200`); byte-identity trivially preserved (nothing
  wired).

- **B2 — intra-def analysis + census.** `borrow-inference-phase2-*.md`.
  Wire `Borrow/{Rty,Constrain,Solve}.elm` + `Borrow.elm` as GlobalOpt
  Phase 6, `reify = ROff`, all boundaries owned; emit the `BorrowStats`
  census. **This is where the oracle first exists.** Add `BORROW_001`.
  **Gate:** emitted-MLIR **byte-identical** flag-on vs off (the load-bearing
  graph-inertness gate); E2E green; first real census published here;
  wall ≤3% with majors recorded; elm-aws-codegen canary linear.

- **B3 — interprocedural signatures.** `borrow-inference-phase3-*.md`.
  `Borrow/Sig.elm` (per-`SpecId` `BorrowSig` via SCC fixpoint) +
  `Borrow/KernelSigs.elm` (seeded from the B0 audit in `design_docs/borrow-inf-census.md`
  §3). Calls stop being all-owned poison. `BORROW_005` test.
  **Gate:** still byte-identical (analysis-only); `sccFixpointBailouts=0`;
  `sigMissReads=0`; census delta vs B2 recorded; wall ≤3%.

- **B3.5 — LSS handshake.** `borrow-inference-phase4-*.md`.
  `Borrow/LssFacts.elm` + `MonoGraph.lssMemberOrigins`; route
  singleton-lambda-set calls through real signatures; `BORROW_006`.
  **Gate:** subst engine **byte-identical to B3** (hard inert gate);
  solver leg E2E green; PoisonCause census published; wall ≤3%.
  **Completing B3.5 = the analysis track is code-complete.**

---

## 5. Sequencing & dependencies

```
B0 (done) ─┐
           ├─ independent / parallelizable
B1 ────────┘
              B1 → B2 → B3 → B3.5
                   ▲oracle first exists here
```

- **B0 and B1 are independent** (no deps; buildable concurrently, now).
- Then a strict chain: **B2 needs B1**, **B3 needs B2**, **B3.5 needs B3**.
- B3.5's own plan notes it *could* slide relative to an early Phase-5 unit
  if the census shows closure-poisoning is small — **moot under Strategy B**
  (no Phase 5); here it is simply the last analysis step.
- Analysis runs under the **default subst engine as all-`LTop`** → the core
  is engine-independent; only the B3.5 LSS handshake is solver-specific.

---

## 6. Track-level verification (applies to every milestone)

Consolidated so it is stated once, not re-derived per phase:

- **Graph-inertness is the defining gate.** From B2 on, every milestone
  must keep emitted MLIR **byte-identical** flag-on vs off. `--text-mlir`
  is byte-canonical; compile the corpus (and self-compile) twice and `cmp`.
  This is what makes the whole track safe to ship inert.
- **Full E2E** via `cmake --build build --target full`, run **once**, teed
  to `/tmp/test_output.txt`, then grepped (never re-run tests — CLAUDE.md).
- **Front-end** via `cmake --build build --target elm-tests`, run
  **serially** with E2E (typed-artifacts cache race).
- **Wall budget ≤3%** cumulative (interleaved self-compile flag-on vs off,
  ×3), **majors recorded alongside every wall** (major-GC trigger lottery).
- **Self-compile is THE gate** for anything the corpus is shaped wrong to
  catch; the corpus is flag-off-shaped and the harness cache is env-blind —
  **touch all test `.elm` before a flag-on leg**.
- **Reconfigure** `cmake --preset build` after adding any new `Borrow/*.elm`
  (ELM_SOURCES is a non-CONFIGURE_DEPENDS glob).
- **`--target full` deletes `bin/eco-compiler` and `eco-boot.js`** — rebuild
  a from-source compiler via `--target eco-compiler` for any census /
  measurement run (Phase-0 lesson).

**Track exit gate (G-B):** B3.5 shipped + all four milestone gates green +
`BorrowStats` census published on the full corpus + wall gate met + the
`Borrow/Check.elm` certifying checker green + T-DECISION-1 recorded.

---

## 7. Exit criteria & escalation (the decision this track defers)

**B is "done" when** B3.5 lands (G-B) and the **B2 static census** is
published on the full corpus. Per **D0.6**, that B2 census — not the
Phase-0 ceiling — is the deciding evidence; it **confirms or overturns**
the §2 call.

**Re-open Strategy A / hand to v2 when** the published census crosses a
stated trigger (design §18 B6, `borrow-inference-phase6-v2-backlog.md`):

- **The primary trigger is arrays/lists entering `rcManaged`** — the ~51%
  data bulk + the Cons allocation mass (≈65% of allocation per the
  cons-reduction survey). That is **v2 backlog item 2**, itself gated
  behind **item 3** (per-ctor field-granular precision). This is where the
  RC payoff the ceiling denies v1 actually lives.
- **A narrow Strategy A** becomes arguable only if the B2 census surfaces a
  concentrated hot pocket the Phase-0 aggregate hid (e.g. a specific
  string-heavy kernel with provably-unique buffers). Keeping B cheap keeps
  that option open.

If neither trigger fires, the track's terminal state (inert oracle +
census) is the shipped end state and this plan closes.

---

## 8. Track deliverable — the oracle-consumer surface (new here)

The value of B without RC ops is that its facts are *consumable*. This is
cross-cutting (produced by B2/B3, consumed elsewhere) and belongs to the
track, not a phase. **Primary deliverable is the oracle + census itself**;
consumers are opportunistic and each is its own future plan:

- **Census-as-sizing** (immediate, in-scope): the `BorrowStats` counters
  are the source of truth for every B6 v2 go/no-go. This is the one
  consumer B *must* deliver — it is the census, already in B2's scope.
- **Uniqueness-informed kernel specialization** (future/opportunistic):
  in-place-when-unique variants of individual kernels can read the oracle
  without any RC machinery.
- **Fusion / cons-reduction legality** (future): the sharing facts can
  inform the fusion work tracked in the cons-reduction investigation.
- **Escape / value-aggregate lowering** (future): the design positions
  borrow analysis as superseding a separate escape analysis (DS-series);
  the oracle is the substrate.

Contract for consumers: read facts through the `Borrow.elm` readback API
(`reifiedMode`/`ltAOf`/`coercionPoints` + `BorrowSig`s); **never** assume an
RC op was emitted (there are none in Strategy B).

---

## 9. Cross-cutting risks (once, for the whole track)

- **Harness env-blindness** — report/enable flags don't change
  `Config.hash`, so the E2E cache is blind to them; **touch all test `.elm`
  before every flag-on gate** or the gate is vacuous.
- **Typed-artifacts cache race** — never run `--target full` and
  `elm-tests` concurrently; serialize; purge `~/.eco` + rerun alone to
  recover.
- **Major-GC trigger lottery** — a wall without its major-GC count is
  uninterpretable; record majors with every wall.
- **32-slot GC-scan record cap** — `Constraints`/`Gen`/`SolveState`/
  `BorrowStats` are self-compiled by eco; a 33rd field fails the backend
  verifier at MLIR parse. Keep each ≤32 fields.
- **`MonoGraph.callEdges` is empty at Phase 6** (not merely stale) — B3
  must re-collect edges; never read `graph.callEdges`.
- **Solver binaries must be minted via the NATIVE binary** (cmake Stage-5
  node OOMs at 4 GB) for any all-keyed self-compile leg.

---

## 10. References

- Parent design: `design_docs/globalopt/borrow-inference-design.md` v2 —
  §7 (RTy/lattice), §8 (constraints), §9 (staged solve), §10 (LSS
  handshake), §11–12 (interprocedural + kernels), §13 (census), §18
  (milestones), §22.1 (the A/B/C call), §20 (BORROW_001-006).
- Phase specs: `plans/borrow-inference-phase{0,1,2,3,4}-*.md` (the B0–B3.5
  implementation detail this track coordinates).
- Deferred (out of scope): `plans/borrow-inference-phase{5,6}-*.md`.
- Evidence / G1: `design_docs/borrow-inf-census.md` (Phase-0 as-built: census, ceiling,
  kernel audit, view decision, header-preservation, the preliminary §22.1
  call).
