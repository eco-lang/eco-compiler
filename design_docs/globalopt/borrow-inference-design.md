# Automatic Borrow Inference in Eco — Design Outline

*Status: OUTLINE v0 (2026-07-10). High-level; captures the shape, the
architecture decision, and the open questions. Detailed design to follow
once the M0 decisions below are made.*

*Basis: Brandon, Driscoll, Dai, Ragan-Kelley, Milano, Aiken — "Fully-Automatic
Type Inference for Borrows with Lifetimes" (OOPSLA 2026),
`design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`.
Companion to the LSS design
(`design_docs/monomorphization/lambda-set-specialization-design.md`) — the
paper's own pipeline runs LSS first (its §6.1) and describes its mode
specialization as "in the mold of LSS" (§6.2). Solver-engine background:
`design_docs/monomorphization/solver-reuse-evaluation.md`. In-repo RC prior
art: `design_docs/perceus_gc/` (study of Roc's Perceus implementation:
borrow signatures, inc/dec insertion, RC codegen).*

---

## 1. Objective

Infer, fully automatically, an ownership discipline for Eco's heap values:
for every heap-typed binding and occurrence, a **mode** — owned (`•`) or
borrowed (`&⟨L⟩`) with a static **lifetime** `L` — such that

- borrowed handles incur **zero** memory-management operations;
- owned handles are **moved** (free) at their final occurrence where lifetimes
  permit, **duplicated** (RC increment) otherwise;
- owned handles not moved are **dropped** (RC decrement / free) at the end of
  the inferred precise lifetime;
- programs the discipline cannot type are *completed* by inserting a minimal
  number of dups — never rejected.

The paper reports 75–100% dup elimination vs a Perceus baseline and a 1.48×
geomean speedup on Morphic. The headline mechanism for Eco is the same one
that carried Morphic's biggest wins: with almost all RC traffic elided,
reference counts become *accurate uniqueness witnesses*, enabling **RC-1
in-place mutation** of logically-immutable structures (arrays, buffers,
records) — the optimization class Eco currently cannot express at all.

**Non-goals (v0):** mutable/exclusive borrows; user-visible annotations
(except possibly the paper's §6.5 identity-`dup` escape hatch, later);
reuse/“destructor-fusion” optimization (Perceus reuse — explicitly out, as in
the paper's baseline).

---

## 2. Placement in the pipeline

Borrow inference requires a **first-order, monomorphic** program with
concrete types (paper §6.1). Eco has exactly one place that satisfies this:
the `Mono.MonoGraph`, after monomorphization and closure work.

```
typecheck → AssignMVarIds → monomorphize (MonoSolver)      Generate.elm:733
          → MonoInlineSimplify                              Generate.elm:762
          → GlobalOpt (MonoGlobalOptimize + LSS/AbiCloning) Generate.elm:780
          → ★ BORROW INFERENCE ★  (new, last GlobalOpt family pass)
          → Generate/MLIR → runtime
```

Ordering constraints:

- **After inlining** (`MonoInlineSimplify`): inlined bodies expose more
  borrowable occurrences; analyzing before inlining would waste precision and
  then invalidate placements.
- **After LSS / AbiCloning cloning** (LSS design §9): defunctionalized,
  specialized call graph = concrete control flow, the paper's stated
  precondition. LSS M3's function-cloning machinery in
  `Compiler/GlobalOpt/AbiCloning.elm` (today a no-op stub) is also the
  natural host for this pass's *mode specialization* (§6 below) — borrow
  inference is its **second client**, not a new cloning mechanism.
- **Immediately before MLIR generation**: dup/drop placements must not be
  perturbed by later Mono-level transforms.
- The paper wants roughly **ANF input** ("borrowing decisions happen at
  variable occurrences", §6.3). Mono IR is let-structured but not ANF;
  either a light normalization pre-pass or constraint-generation that treats
  compound subexpression results as anonymous bindings. Decision deferred to
  detailed design.

---

## 3. The strategic decision first: what do the results *drive*?

This is the load-bearing open decision, and it is a **runtime** decision, not
a compiler one. The paper's system elides RC operations — but Eco's runtime
is a **tracing generational GC** (nursery/OldGen, HPointer, statepoints);
there are no RC operations to elide today. Three consumption models, not
mutually exclusive over time:

**Option A — full RC mode.** Replace tracing GC with Perceus-style RC plus
borrow elision (the Morphic/Koka model; `design_docs/perceus_gc/` documents
Roc's version). Maximal payoff, maximal cost: object headers gain a count,
the entire statepoint/RS4GC/nursery machinery is bypassed or dualized, every
HEAP_* invariant is touched. Not credible as a first step.

**Option B — hybrid: RC only for flat, expensive-to-copy buffers.** This is
in fact what Morphic itself does ("the only RC'd objects in Morphic are
arrays and the pointers breaking recursive types"). Eco analog: Array
buffers, ByteBuffers/large string leaves get a count and participate in
dup/drop + RC-1 in-place mutation; cons cells, records, customs, closures
stay traced. Contained blast radius; captures the paper's two biggest
measured wins (RC-1 arrays; string/buffer traffic).

**Option C — no RC: static facts only.** Use inferred modes/lifetimes purely
statically: where inference produces *zero dups* along all paths to a
mutation site, the value is statically unique → in-place update without any
dynamic count; plus earlier-free hints and better stack-allocation decisions
(complementing the existing unboxed-aggregates work,
`design_docs/escape-analysis.md`). Cheapest; strictly weaker (static
uniqueness is all-or-nothing where RC-1 is per-run).

**Recommendation:** an M0 foundation report (mirror of
`lss-foundation-report.md`) decides A/B/C with measurements — instrument the
current runtime to count would-be dup/drop sites and GC pressure per
benchmark. Provisional lean: **B**, with C's static-uniqueness consumer as a
free byproduct. Critically, §4–§6 below — the analysis itself — are
**identical under all three options**; only reification (§6 phase R) and the
runtime work differ. The analysis can therefore be built and validated
(dup-count statistics, no codegen) before the runtime decision is final.

---

## 4. Architecture: reuse the solver engine, add one primitive

Per the solver-reuse evaluation, the engine's Architecture-C pattern (fresh
per-work-item union-find store, demand-driven worklist + registry, load/zonk
boundary) is the right host. But the paper's solver is **not unification**:
its core (paper Fig. 8) is Datalog-style *directed inequalities* over finite
lattices, solved by Kleene iteration (modes: `& < •`; lifetimes: a finite
tree lattice). Encoding those as unification would collapse every
flow-connected component to one mode — re-creating precisely the *poisoning*
the system exists to avoid.

Reuse map:

| Engine asset | Role here |
|---|---|
| Per-item store + `MVarId → Point` memo (`MonoSolver/Engine.elm`, `Store.elm`) | Mint one **resource variable** (Point) per heap position of each `MonoType`; per-function analysis scope |
| `Unify`/`UnionFind` | The *equality-constrained subset*: storage modes of nested heap positions (paper §3.3), structural pairing of resource vars when types match |
| Worklist + `Registry` (`enqueueSpec` pattern) | **Mode specialization**: specialize functions per demanded (MonoType × mode/lifetime signature), dedup by comparable key |
| Attribute-on-class harvest (`harvestSuperTable` precedent; LSS set-content precedent) | Mode/lifetime facts living on union-find class representatives |
| Golden-gate / A-B diff methodology | Migration discipline (§8) |

New machinery (the genuinely missing pieces):

1. **Lifetime lattice module.** The paper's structural lifetimes: trees over
   the function's control skeleton with `⊔`, `≤`, boundary/exceeds checks
   (`≍`, `≺`), path concatenation; lifetime *variables* `α` with formal joins
   for function summaries. Finite per function (bounded by branching depth)
   → termination for free.
2. **Monotone propagation solver.** A directed constraint graph over
   resource-variable *class representatives* (union-find compresses first,
   propagation runs on the quotient — standard hybrid), with a worklist that
   joins lattice values along edges to a least fixed point. Small (~a few
   hundred lines), generic over the lattice.
3. **Staged fixpoints.** Three runs over the same graph, per the paper:
   approximate lifetimes → modes (escape conditions evaluated against stage-1
   results) → precise lifetimes. The engine currently has no "re-run a
   stage" notion; this lives in the new pass, not in `Unify`.
4. **SCC summary iteration.** Recursive functions need
   re-enqueue-callers-when-summary-grows (function signatures carry lifetime
   variables whose argument-side joins grow to a fixed point, paper §5.1).
   The registry's specs are immutable-once-created today; the borrow pass
   needs a summary-invalidation wrapper around it.

---

## 5. Core data model (sketch)

- **Resource-annotated MonoType.** For each heap position of a `MonoType`
  (everything that is `!eco.value` at runtime: strings, lists, tuples,
  records, customs, closures, boxes — NOT Int/Float/Char, per REP_*
  invariants), a resource variable carrying `(storageMode, accessMode)`
  (paper §3.4). Unboxed scalars and value-level aggregates (escape-analysis
  forms) are "stack values": never borrowed, cheap to copy — exactly the
  paper's treatment.
- **Modes** `& < •` per resource; **lifetimes** per §4.1; **binding vs value
  types** (owners additionally carry the lifetime used to place drops).
- **Function summaries**: per mode-specialized signature — argument/return
  types with modes and lifetime-variable joins relating returns to
  parameters. Stored beside (eventually: inside) the existing registry
  entries.
- **Guardedness** (paper §5.2) is structurally satisfied in Eco: every
  recursive-type occurrence is already behind a heap pointer (all
  constructors box). No re-typing pass needed; the annotation scheme just
  distinguishes top-level vs nested resources.

---

## 6. Pass structure

```
Phase N  (maybe) ANF-ish normalization of Mono bodies          [§2 decision]
Phase L  Lift: annotate each def's types with fresh resource
         vars; syntax-directed walk emits constraints
         (flow, scope, equality, get/access, escape seeds)
Phase S1 Fixpoint: approximate lifetimes  (mode-oblivious escape analysis)
Phase S2 Fixpoint: modes                  (escape ⇒ owned; unify equalities;
                                           owned-occurrence ⇒ owned-binding)
Phase S3 Fixpoint: precise lifetimes      (lateral/vertical flow, mode-gated)
Phase M  Mode specialization: clone defs per demanded mode signature
         (via AbiCloning machinery); SCC summary iteration wraps L–S3
Phase R  Reification: lower occurrence casts to borrow/move/dup;
         insert drops at precise-lifetime ends; slide drops early;
         preserve tail calls (treat tail-call args as escaping in S1,
         paper §6.3)
Phase V  (debug gate) Verify: type-check the reified program against the
         L&-style rules — the paper's soundness story is precisely that
         inference output is *certifiable*; keep as an ECO_DEBUG check
```

Reification target is a named decision point: new Mono node kinds
(`MonoDup`/`MonoDrop`) consumed by `Generate/MLIR`, vs emitting `eco.rc_dup`/
`eco.rc_drop` ops directly in the Eco dialect. Lean: MLIR ops (later passes
and LLVM see them; codegen stays a thin translation), with the Mono level
carrying only the annotations.

---

## 7. Eco-specific concerns (each needs a section in the detailed design)

- **Kernel borrow signatures.** Every C++ kernel function needs an
  ownership/borrow signature (Roc's `borrow.rs` is the model — see
  `perceus_gc/borrow.md`). This is the borrow-flavored twin of the
  MonoSolver "kernel honesty" frontier (solver-reuse §6.3) and likely the
  largest grind. Default for unannotated kernels: all-owned (sound,
  Perceus-equivalent).
- **Embedded constants.** True/False/Empty/unit are HPointer constants
  (CONSTANT_TAG dispatch) — statically immortal, mode-irrelevant; the
  analysis should give them a distinguished "no-RC" mode so they never
  generate constraints or ops. Same for interned string literals
  (thread-local + heap-generation epoch interning).
- **String/byte views** (HEAP_028–032). A `StringUtf8View`/slice *is* a
  borrow of its backing buffer materialized as data. Under option B these
  need a coherent story: either views hold a count on the backing buffer
  (dup at view creation — partially defeating zero-copy) or the analysis
  proves the backing outlives the view (the common case; slices become the
  showcase for lifetime inference). Flag: this interacts with the
  slice-narrowing/healing machinery.
- **Closures.** Post-LSS, capture environments are concrete heap objects;
  captured heap values are nested resources of the environment. LSS's
  id-only lambda sets tell us *which* environments flow to a call site —
  the LSS design already names borrow-inference seeding as a consumer.
- **Concurrency.** Ports/embedding run kernel work off the Elm thread
  (TSFN teardown races are known territory). If any RC'd object can cross
  threads, counts must be atomic or ownership transfer must be explicit at
  the boundary. Assumption to validate in M0: Elm-side heap is
  single-threaded; boundary objects are copied.
- **GC coexistence (option B).** Traced objects may point to RC'd buffers
  and vice versa; the GC must treat counts as part of object identity
  (moving/copying an RC'd buffer is forbidden or count-preserving), and
  drops reaching zero inside a GC'd graph need a deallocation path. This is
  where HEAP_* invariants get their new siblings.
- **Effects of `Debug.log`-style observation and exceptions/crashes**: drops
  on abnormal exit paths — likely "leak on crash is fine", but state it.

---

## 8. Testing and migration

- **Metric-first development.** The analysis phases (L, S1–S3) land long
  before reification: run over the full E2E corpus emitting *statistics*
  (borrowed/owned/dup counts per def) and diff those as the golden artifact.
  The paper's own evaluation metric (dynamic dup count) becomes our gate
  once reification exists — instrument dup/drop as counters behind
  `ECO_RC_STATS`.
- **A/B discipline** exactly as MonoSolver: `eco-config` /
  `ECO_BORROW_ENGINE` gate; all-owned mode (constrain every mode to `•`)
  reproduces Perceus behavior and doubles as the baseline and the
  soundness-isolation tool.
- **Verification gate** (Phase V) on in debug/CI builds initially.
- **Benchmark gate** per phase: self-compile wall time + the known
  pathological inputs (elm-aws-codegen), same discipline as the GlobalOpt
  staging incident and backend perf rounds.
- **Milestones (sketch):**
  - **M0** — foundation report: runtime strategy decision (§3), kernel
    signature inventory, dup-site instrumentation numbers.
  - **M1** — lifetime lattice + propagation solver, unit-tested standalone.
  - **M2** — intra-function L + S1–S3 over MonoGraph, stats only.
  - **M3** — function summaries + SCC iteration + mode specialization
    (piggybacking AbiCloning), stats only.
  - **M4** — reification + minimal runtime (per M0 decision) behind flag;
    E2E green with flag on; RC-1 in-place array/buffer mutation.
  - **M5** — evaluation vs baseline; default-on decision.

---

## 9. Open questions

1. §3 strategy (A/B/C) — the M0 report's job. Everything in §7 "GC
   coexistence" hangs on it.
2. ANF normalization vs ANF-tolerant constraint generation (§2).
3. Reification target: Mono nodes vs Eco-dialect ops (§6).
4. Where mode-specialization keys live relative to LSS specialization keys —
   one registry keyed by (type, lambda-set, modes) or layered clones?
   (The paper suggests merging specializations with identical RC behavior.)
5. Drop-sliding vs GC safepoint placement: does an early drop create
   liveness the statepoint machinery must know about (option B)?
6. The §6.5 escape hatch (user-guided dup placement): expose in Elm source
   or keep internal-only?
7. Lifetime representation at function boundaries once Eco's real control
   constructs (case/decision trees, joinpoints) replace the paper's
   if-only skeleton — the lattice generalizes (n-ary alternation), but the
   detailed design must fix the skeleton extraction from Mono bodies.

---

## 10. References

- Paper: `design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`
- LSS: `design_docs/monomorphization/lambda-set-specialization-design.md`,
  `lss-foundation-report.md`
- Solver engine: `design_docs/monomorphization/solver-reuse-evaluation.md`,
  `Compiler/MonoSolver/{Engine,Store,Translate,Zonk}.elm`
- Pipeline: `compiler/src/Builder/Generate.elm:721-790`
- Cloning host: `compiler/src/Compiler/GlobalOpt/AbiCloning.elm` (stub)
- RC prior art: `design_docs/perceus_gc/` (Roc Perceus study)
- Stack allocation complement: `design_docs/escape-analysis.md`,
  `escape-analysis-status.md`
- Invariants to review before implementation: `design_docs/invariants.csv`
  (REP_*, HEAP_*, CGEN_*, FORBID_*)
