# Automatic Borrow Inference in Eco — Detailed Design

Status: **DETAILED DESIGN v2 (2026-07-21).** Supersedes DETAILED DESIGN v1
(2026-07-10) and the v0 outline. Basis: Brandon, Driscoll, Dai,
Ragan-Kelley, Milano, Aiken — *"Fully-Automatic Type Inference for Borrows
with Lifetimes"* (OOPSLA 2026),
`design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`
("the paper"). Companion analyses: LSS design
(`design_docs/monomorphization/lambda-set-specialization-design.md`), the
escape-analysis postmortem (`design_docs/escape-analysis-status.md`,
2026-05-21), the LSS census settlements
(`plans/lss-dispatch-value-extraction.md` §12).

This revision is a full rewrite prompted by five design questions:

1. Does borrow inference supersede the earlier escape-analysis work? (§2)
2. How does it relate to LSS — separate phase or overlapping, and where
   does it go in the pipeline? (§3)
3. How does it serve eco's reference-counting + optimistic-mutation goal,
   given the reserved `eco.incref`/`eco.decref` ops? (§4)
4. How exactly does the stable LSet/srcLambda query API work, so that
   where LSS knows a singleton, borrow routes through the member's real
   signature instead of poisoning? (§10)
5. LSS and borrow are the same *shape* of analysis — can they share
   implementation, and is there an advantage? (§5)

All code references were re-verified against the tree as of 2026-07-21
(post P2.5/R5 allocator work, post all-keyed LSS Fix B).

**Sequencing principle for the whole program:** the borrow-inference
*analysis* is designed and implemented first, as a standalone,
graph-identical pass with a census — valuable on its own as a static
uniqueness/sharing oracle. The *optimizations* that consume it
(RC reification, runtime RC path, RC-1 optimistic mutation) are derived
afterwards, each sized by the census before it is built. The document is
organized in that order: Part I positions the pass (the five questions),
Part II specifies the analysis, Part III the consumers, Part IV the
program.

---

## 0. Decision summary

Decisions DS1–DS6 carry over from v1 (re-verified, stale anchors fixed);
DS7–DS11 are new in v2, one per investigation question.

- **DS1 — No reuse of `Type.Unify`/`Type.UnionFind`.** After
  monomorphization every type is a ground `MonoType`
  (`Monomorphized.elm:202`); `MVar _ CEcoValue` is an *erased opaque*
  type, not an inference variable. The only inference objects are the
  pass's own resource variables — dense `Int`s, quotiented by a dedicated
  ~80-line union-find (`Borrow/Dsu.elm`, §7.1). Structural constraint
  broadcast is a deterministic zip of ground types — no `FlatType`, no
  solver store. Critically, borrow's `flow ≥` constraints are *directed*
  and must never be collapsed by unification (v0's fatal mistake). What
  IS inherited from MonoSolver/LSS is the architecture pattern and shared
  utilities — see DS11/§5.
- **DS2 — Zero `MonoType` blast radius.** Unlike LSS (whose annotation
  rides `MonoType` through mono — a 159-site sweep), borrow inference
  runs entirely inside one GlobalOpt pass. `RTy` (§7.3) is pass-internal.
  The only AST change: two new `MonoExpr` constructors added at
  reification (§14), touching the 13 files that pattern-match `MonoExpr`
  — only 2 non-trivially.
- **DS3 — Pipeline position: GlobalOpt Phase 6, after
  `annotateCallStaging`.** Sharpened in v2 with the full rationale in
  §3.2: it must run after Phase 4 (AbiCloning) and Phase 5
  (annotateCallStaging) so that `CallInfo.callKind` and the AbiCloning
  singleton stamps (`fastEvaluator`/`captureAbi`) are materialized
  facts, and so no later Mono pass observes the new constructors.
- **DS4 — ANF not needed (deliberate deviation from the paper).** The
  paper prescribes ANF conversion because borrowing decisions attach to
  variable occurrences (paper §6.3). In eco's Mono IR the attachment
  points all exist without normalization: RC decisions attach at
  `MonoVarLocal`/`MonoVarGlobal` occurrences, at projection outputs, and
  at call/kernel-result coercion points (§14.2) — every one of which is
  a concrete node in the nested IR. Nothing multiply-consumed exists
  without a let binding, and a nested operand's RC behavior is fully
  determined by the occurrences and coercion points *inside* it (e.g. a
  `case` operand's arms each carry their own `Occ`s). Because this is a
  deviation from the paper, B2's census carries validation counters
  (`nonVarOperandHeapResults`, split by borrowed-producer vs
  owned-fresh producer) to confirm no attachment point is being lost to
  nesting (§13).
- **DS5 — v1 interprocedural model: one borrow signature per `SpecId`,
  no mode cloning.** Mode specialization (paper §6.2) requires function
  cloning. *(v1's anchor here is stale: `AbiCloning.abiCloningPass` is no
  longer a stub — it is a fully built 1,546-line pass, and keyed mono
  specialization is the shipped LSS default. The cloning substrate now
  exists.)* The decision stands anyway: v1 computes a single signature
  per specialization and *measures* poisoning (per-param counters for
  "forced owned by a minority of call sites", §11.2); v2 adds mode
  specialization on the now-real keyed/AbiCloning substrate, sized by
  those counters. Closure boundaries and kernels default to all-owned in
  v1, upgraded by the LSS facts channel (§10) and the audited kernel
  table (§12).
- **DS6 — The copying-nursery insight narrows where RC pays.** The
  nursery is a copying space: dead nursery objects cost nothing at minor
  GC, so early drop/free of a nursery object buys no memory back. There
  is **no per-object free API** in the allocator — deallocation exists
  only as old-gen sweep into `Tag_Free` segregated free lists
  (HEAP_021/023; the one mid-cycle precedent is `freeLargeBodyCell`,
  HEAP_027). RC reification therefore pays only for (a) RC-1 in-place
  mutation decisions and (b) old-gen/pinned objects — most notably large
  string/byte bodies, already pinned and individually reclaimed
  (HEAP_026). This scopes `rcManaged` v1 to **pointer-free flat
  buffers** (§16.1). Dup *elision* remains valuable wherever counts are
  maintained; elsewhere the analysis still yields static uniqueness facts
  and statistics.
- **DS7 (new, Q1) — Borrow inference supersedes the escape-analysis
  *analysis*; the value-aggregate *lowering machinery* is retained as a
  future consumer.** The two escape passes and their interprocedural
  worker/wrapper engine have already been deleted from the tree; the
  postmortem's rejection census maps line-for-line onto defects that a
  signature-based, pre-codegen lifetime analysis removes (§2.2). No part
  of the deleted analysis is worth reviving. The surviving `eco.make.*`
  dialect surface, `EcoToLLVMValueAgg.cpp`, the SROA-before-RS4GC
  pipeline ordering, and the logical-types metadata channel are kept as
  consumers/mechanisms for a later unboxing pass fed by borrow facts
  (§2.3).
- **DS8 (new, Q2) — Separate phase from LSS, by necessity, not taste.**
  LSS is a *control-flow* analysis that must run inside monomorphization
  (its member↔global/kernel reverse maps live only in engine state and
  are consulted by in-mono devirtualization); borrow is a *data-lifetime*
  analysis that needs the final, fully-specialized graph. This mirrors
  the paper's own architecture (paper §6.1: monomorphize + LSS first,
  "types and control flow should be concrete"). Also load-bearing: the
  compiled-in default mono engine is still `EngineSubst`
  (`Config.elm:231`), which produces all-`LTop` graphs — the borrow pass
  must be engine-independent in its core and *inert-graceful* in its LSS
  upgrade (§3.3).
- **DS9 (new, Q3) — The reserved RC dialect ops are the reification
  target; optimistic mutation is the north-star consumer.** Verified
  current state: six placeholder ops (`Ops.td:2751-2842`), a reserved
  15-bit `Header.refcount` field at bits [16,30] that nothing reads or
  writes, and `RCElimination` as a pure hard-error verifier
  (first pass of `buildEcoToEcoPipeline`, `EcoPipeline.cpp:53`). v1
  consumes `eco.incref`/`eco.decref`/`eco.free`; `eco.decref_shallow`
  activates with the v2 arrays child-walk; `eco.reset`/`eco.reset_ref`
  (Perceus reuse tokens) remain reserved beyond v2 (§4.2).
- **DS10 (new, Q4) — LSS facts reach borrow through three surviving
  channels plus one new export.** Surviving post-mono:
  `LambdaSetAnno` on every `MFunction` arrow; `ClosureInfo.{lssMember,
  srcLambda}` on every `MonoClosure`; the AbiCloning stamps on
  `CallInfo`. NOT surviving: the member→global/kernel reverse maps
  (they die with engine `S` at mono exit) — so standalone `g|`/`k|`/`c|`/
  `a|` members inside an `LSet` are opaque integers post-mono. v2 adds a
  compact `lssMemberOrigins` export on `MonoGraph` to close that gap.
  `Borrow/LssFacts.elm` (§10) resolves call sites through these channels
  with a strict decline ladder (blocked ⇒ poison; multi-member ⇒
  asymmetric meet) whose soundness direction follows RC_001: params
  any-owned-wins, results any-borrowed-wins.
- **DS11 (new, Q5) — Share utilities and disciplines with LSS, never the
  solving machinery.** LSS's lattice lives inside solver-store `Point`
  content, joined by unification, demand-lazily, in-mono; borrow's is a
  directed flow lattice over a finished graph. The concrete reuse
  inventory (§5.3): `Compiler.Graph` stack-safe SCCs, the
  `buildCallGraph` dense-indexing scaffold (copied, keeping the SCC
  list), the Staging `UnionFind` DSU core (copied into `Borrow/Dsu`),
  `Compiler.Data.BitSet`, the census/stats/report plumbing pattern, and
  LssInfer's disciplines (memoized per-SCC signatures, re-entry guards,
  poison-on-mismatch totality, AbiCloning's first-order-recursion scale
  lesson). Roughly 40–50% of the pass skeleton exists; 0% of the core
  solver does.

**Disposition of v1's open questions:** OQ-M0 (runtime strategy A/B/C
call) — still open, B2 census decides (§22.1). View counting — open
(§22.2). `resultAliases` conditional kernels — open, audit item (§22.3).
`MonoRcDup` selectors — deferred to per-ctor precision, v2 (§22.4). JS
backend — v1 `reify=rc` rejected for JS targets, analysis still runs
(§22.5). New in v2: engine-default question (§22.6), capture borrowing
(§22.7), certifying-checker depth (§19.3).

---

# Part I — Positioning

## 1. Objective and scope

Infer, per specialization, an ownership discipline for heap values: each
heap-typed binding and occurrence gets a **mode** — owned (`•`) or
borrowed (`&⟨L⟩`) with a static **lifetime** — such that:

- borrowed handles compile to nothing;
- owned final uses compile to moves (nothing);
- owned non-final uses compile to `eco.incref`;
- unmoved owned bindings compile to `eco.decref` (or `eco.free` when
  statically unique) at scope end, bounded by their precise lifetime
  (placement rules §14.2).

Programs the discipline cannot type are *completed* with dups, never
rejected (the paper's totality guarantee; the fully-pessimistic all-owned
solution "amounts to the Perceus RC technique", paper §3.1).

Deliverables, strictly in dependency order:

1. **The analysis** (modes + lifetimes + signatures) with a census
   report — graph-identical, engine-independent, valuable stand-alone as
   a static uniqueness/sharing oracle (B1–B3).
2. **The LSS handshake** — closure-boundary upgrade where lambda sets are
   known (solver engine only) (B3.5).
3. **Reification** to the existing dialect RC ops behind a flag, plus the
   certifying checker (B4).
4. **Runtime RC path** scoped by `rcManaged` (B4).
5. **RC-1 in-place mutation** for the scoped buffer types (B5).

**Non-goals (v1):** exclusive/mutable borrows; Perceus reuse
(`eco.reset`/`eco.reset_ref` stay reserved); mode specialization (v2);
drop-sliding (v2 — but see §17's C1 for why it matters); user-facing dup
escape hatch; multi-threaded RC.

**What borrow inference is *not* for.** The 2026-07 LSS census campaign
settled that the residual ~641.7M generic dispatch events per self-compile
(Run Q: `gen=641,694,578` of `sat=658,526,335`) are dominated by IO-bind
continuations whose lambda sets are ⊤ *by soundness* — the continuation
escapes into the returned IO value
(`plans/lss-dispatch-value-extraction.md` §12, "E8-or-nothing"). Borrow
inference does not devirtualize anything and does not recover that
dispatch cost; defunctionalization (E8) remains the only answer there.
At those same ⊤ boundaries, borrow inference degrades to the Perceus
baseline (all-owned RC), which is *sound and complete* — the cost is
extra RC traffic at poisoned boundaries, not correctness. The paper's
evaluation calibrates expectations for what borrow *does* buy: 75–100%
dup elimination on 11/13 benchmarks, 1.48× geomean over a Perceus
baseline, with the biggest wins on read-heavy state-threading code
(parser combinators: calc 2.67×, parse_json 3.01× — the baseline spent
>60% of runtime on RC traffic). Eco's self-compile is exactly such a
workload. But note DS6: eco is not Morphic — eco's RC is an *accelerator
over a tracing GC*, so wins arrive through RC-1 mutation, old-gen
reclaim, and static uniqueness, not through allocation avoidance.

## 2. Relationship to the escape-analysis work (Q1)

### 2.1 What existed, and what it measured

The prior escape work lived entirely on the **MLIR/C++ backend**, on
lowered IR, in two layers (full record:
`design_docs/escape-analysis-status.md`, 2026-05-21):

1. A local per-function pass (`EcoEscapeAnalysis`, ~215 LoC): binary
   `{non_escaping, escapes}` per `eco.construct.*` result, verdict
   "non-escaping iff every use is the matching projection". On
   self-compile it classified **30,908 of 30,910 constructs as escaping —
   2 rewrites total**. Effectively a no-op from day one.
2. An interprocedural worker/wrapper engine (`EcoUnboxedAggCrossSpec`,
   ~2,700 LoC): fixpoint eligibility over the call DAG with per-SCC inner
   fixpoints, splitting eligible functions into `@f$unboxed` aggregate-ABI
   workers plus boxed wrappers. Of 51,485 admitted slots it accepted
   4,741 producer-side and 757 use-side.

The end-to-end A/B was net negative on allocation volume (+102.68 MB,
+5.5M extra small objects) against modest footprint wins (peak −86.7 MB,
live −109.9 MB, major GC −0.39 s). **The entire pass stack and its flags
have since been deleted from the tree**; what survives is the lowering
machinery and the postmortem.

### 2.2 Why it under-delivered — and what a signature-based lifetime analysis fixes

The postmortem's rejection census maps directly onto structural defects,
each of which the borrow design removes:

| Recorded blocker (census) | Root defect | How borrow inference removes it |
|---|---|---|
| `eco.papExtend` 27,238 producer (89%) + 8,305 use rejections | No vocabulary for closures at all; captures = escape | Closure captures are ordinary constraint positions; the LSS facts channel (§10) gives specialized closures real signatures |
| Callee-eligibility coupling: 25,146 + 26,500 rejections | "Call to a not-yet-rewritten callee = escape" — analysis entangled with its own transformation | **Signatures** summarize param/result lifetime behavior independently of whether any transformation applies (§11) |
| `eco.safepoint` 66,126 (82%) of use rejections | Wrong pipeline altitude: analyzing lowered MLIR means fighting IR plumbing | Borrow runs pre-codegen on `MonoExpr`, where safepoints, papExtend and SCF forms do not exist (§3.2) |
| Returns-as-escape (~40% of local verdicts; ~12k constructs) | Binary escape domain cannot express "escapes into the result, until the caller is done" | Result lifetimes `LParams s` express exactly this (§8.3, paper §5.1) |
| Loop carries (`scf.while`/`eco.joinpoint`), 3–4k each side; designed, never built | Bespoke region-walking required per IR form | A lattice fixpoint over ground types handles loop-carried flows as ordinary constraints |
| `eco.case` producer path disabled (5,742) after an OOB crash | Fragile IR surgery in the analysis itself | The analysis rewrites nothing (reification is a separate, trivial wrap pass) |
| Binary domain overall | "Escapes" with no *until when / into what* | Lifetimes replace the bit; last-use/borrow distinctions become expressible |

Verdict on Q1: **yes — borrow inference supersedes the escape analysis
entirely.** Nothing of the deleted analysis is worth reviving; its
successor is strictly more expressive, at the right pipeline altitude,
and decoupled from any transformation.

### 2.3 What is retained (consumers, not analysis)

Still in tree, live, and deliberately kept as the *mechanism* layer for a
future unboxing consumer of borrow facts:

- The value-aggregate dialect surface: the six aggregate types,
  `eco.make.*`, `eco.to_heap`/`eco.from_heap`/`eco.make.closure` +
  verifiers, `Eco_AnyValueOrAggregate` operand widening.
- `EcoToLLVMValueAgg.cpp` (with the safepoint-safe to_heap patterns and
  the P2.5/R5-era inline store shapes).
- The `mem2reg → SROA → FoldExtractValuePass → RewriteStatepointsForGC`
  ordering (`EcoPtrIntVerify.cpp`) that makes register-resident
  aggregates GC-safe.
- The logical-type attribute channel (`LogicalTypes.elm` DSL, CGEN_065) —
  currently consumer-less, but exactly the shape of metadata channel a
  borrow-fact export to the backend would use.
- The ABI knowledge: Sret-outparam for GC-pointer-carrying results, the
  `kMaxDirectFields = 3` StatepointLowering wall, store-before-return
  discipline (CGEN_064/067).

Representation-forced limits that **no** analysis improvement removes
(keep them in scope when sizing any future unboxing consumer): heap
fields are single 64-bit slots, so aggregates stored into heap objects
box; the recursive cons spine; the boxed ABI at closure/PAP/foreign
boundaries; RS4GC's nested-FCA limitation.

### 2.4 Housekeeping debt (separate work, recorded here)

The deletion left stale state that should be reconciled independently of
this design: invariants CGEN_061–067, CGEN_025's make-clause and
REP_AGG_001 still describe the deleted passes as "enforced"; ~42 stranded
`cross_spec_*`/`flatten_*`/`specialize_*` fixtures in `test/codegen/`
reference the removed `-enable-unboxed-agg` flag (mostly vacuous because
the harness ignores unknown RUN flags and silently drops `// CHECK-DAG:`
lines); the front-end still stamps consumer-less
`eco.logical_param_types` attrs. None of this blocks borrow work.

## 3. Relationship to LSS, and pipeline position (Q2)

### 3.1 Complementary analyses, one architecture

LSS answers **"who can be called here?"** (control flow); borrow
inference answers **"how long does this value live, and who owns it?"**
(data lifetime). They compose in exactly one direction: concrete control
flow makes lifetimes inferable. This is the paper's own architecture —
higher-order/polymorphic source is pre-lowered by monomorphization +
LSS-style defunctionalization precisely so "types and control flow
should be concrete, so the most precise lifetimes and modes can be
inferred" (paper §6.1), and LSS's per-call-site specialization is what
avoids interprocedural *poisoning* (Wansbrough–Peyton Jones). Eco
mirrors this: mono + LSS run first (inside the MonoSolver engine),
borrow runs after, consuming LSS's outputs as facts.

They are **not** the same pass and cannot be merged:

- LSS must run *inside* monomorphization: its member interning tables and
  the member→global/kernel reverse maps live in engine state
  (`Engine.LssMemberTable`, `Engine.elm:128-137`) and are consulted by
  in-mono devirtualization (E9/E9.2); the graph is still growing
  demand-driven while it runs.
- Borrow needs the *finished* graph: signatures are per-`SpecId` over the
  final call graph, after inlining, staging rewrites, and AbiCloning have
  settled call shapes. Running it in-mono would re-analyze under a moving
  graph and could not see GlobalOpt's wrappers at all.

### 3.2 Placement: GlobalOpt Phase 6

The GlobalOpt pipeline (`MonoGlobalOptimize.elm:125-152`, driven from
`Builder/Generate.elm` `runGlobalOptPhase`):

```
[pre-pass] MonoInlineSimplify.optimize          (Generate.elm:807)
Phase 1    wrapTopLevelCallables
Phase 2    Staging.analyzeAndSolveStaging       → dynamicSlots
Phase 3    Staging.validateClosureStaging       (GOPT_001/003)
Phase 4    AbiCloning.abiCloningPass            (LSS singleton stamps)
Phase 5    annotateCallStaging dynamicSlots     (CallInfo derivation;
                                                 preserves Phase-4 stamps)
Phase 6    Borrow.run borrowConfig              ← THIS PASS
```

Why exactly here:

- **After Phase 5:** `CallInfo.callKind`
  (`CallDirectFlat`/`CallDirectKnownSegmentation`/`CallGenericApply`/
  `CallSegmentationUnknown`) and stage arities are stamped — the §8.3
  call-boundary dispatch keys off them.
- **After Phase 4:** the AbiCloning stamps (`closureKind = Known …`,
  `captureAbi`, `fastEvaluator`, `fastPapPrefix`) are materialized,
  P4-verified singleton facts that §10.3's query consumes directly.
- **Last:** no other Mono pass ever observes the reified
  `MonoRcDup`/`MonoRcDrop` constructors (BORROW_002); MLIR emission is
  the only downstream consumer.
- Staging wrappers and inliner copies are final, so per-def analysis sees
  the code that will actually be emitted.

`globalOptimize` gains the config parameter and a stats slot exactly the
way `runInlineSimplifyPhase` threads `ecoConfig.inline`
(`Generate.elm:777`): `globalOptimizeWithStats` extends its
`GlobalOptStats` record with a nested `borrow : BorrowStats` field, and
`runGlobalOptPhase` prints the gated census line to **stderr, never
stdout** (MLIR text mode owns stdout — `Generate.elm:744-745`).

### 3.3 Engine reality: subst default, solver sets

A fact this design must not paper over: the compiled-in default mono
engine is **still `EngineSubst`** (`Config.elm:231`); `defaultLss`
(enabled, all-keyed — `Config.elm:115-124`) takes effect only under
`EngineSolver`, selected via `eco-config.json mono.engine` or
`ECO_MONO_ENGINE`. The subst engine cannot produce lambda sets — every
arrow is `MFunction LTop …` by construction (`Config.elm:70-73`).

Consequences, baked into the design:

- **B1–B3 and B4 are engine-independent.** The core analysis treats `LTop`
  closure boundaries as all-owned poison (the Perceus baseline) and is
  correct and useful on subst graphs.
- **B3.5 (the LSS handshake, §10) is solver-only** and must be
  inert-graceful on all-`LTop` graphs — the AbiCloning pattern: an empty
  member index means every query answers `Poison` and the pass behaves
  identically to B3. No configuration coupling: the borrow pass never
  asks which engine ran; it only inspects the annotations and indices in
  front of it.
- The B3.5 census delta (poisoning recovered under solver vs subst) is
  itself an input to the standing engine-default decision (§22.6).

## 4. Relationship to reference counting and optimistic mutation (Q3)

### 4.1 The groundwork, exactly as it stands

Verified 2026-07-21:

- **Dialect ops** (`Ops.td:2751-2842`, section "Reference Counting
  Placeholders (Future Perceus Support)") — six ops, all parse/verify but
  have **zero lowering and zero runtime support**:
  `eco.incref` (`:2761`, args `Eco_Value $value, I64Attr $amount` — the
  batched-amount attr already exists), `eco.decref` (`:2777`, recursive
  free at zero), `eco.decref_shallow` (`:2790`), `eco.free` (`:2803`,
  "known to have reference count 1"), `eco.reset` (`:2816`) and
  `eco.reset_ref` (`:2830`) — the two Perceus reuse-token analogs (note:
  `reset_ref`'s documented "update mode" has no corresponding attribute).
- **Pipeline guard**: `RCElimination.cpp:34-69` is a pure verifier — it
  `emitError`s and fails on any of the six ops; it runs unconditionally
  as the **first** pass of `buildEcoToEcoPipeline`
  (`EcoPipeline.cpp:53`). Any RC op reaching the backend today is a hard
  compile error.
- **Header field**: `u32 refcount : 15` at `Heap.hpp:160`, occupying bits
  [16,30] of the 64-bit header (tag 5 + color 2 + pin 1 + age 2 +
  unboxed 6 = 16 bits below; `builder` is bit 31, `size` bits [32,63]).
  Nothing initializes or reads it anywhere.
- **Absent**: runtime helpers (no `RefCount.cpp`, no `eco_rc_*`
  symbols), compiler-side emission (no `Borrow/` directory, no
  `MonoRcDup`/`MonoRcDrop`), any uniqueness-check op, any kernel
  copy-on-write branch (grep of `elm-kernel-cpp` finds only the
  builder-bit machinery), and any BORROW_*/RC_* rows in
  `invariants.csv`.
- **Mutation precedent**: the builder header bit
  (`Heap.hpp:135-152`, HEAP_BUILDER_001–003) — nursery-pinned
  under-construction objects are the *only* sanctioned mutation today.

### 4.2 The consumption plan

Borrow inference is the analysis that makes the reserved ops *emittable
soundly and profitably*:

| Op | Consumed | By |
|---|---|---|
| `eco.incref` (with `$amount` batching) | v1 (B4) | owned non-final occurrences (§14) |
| `eco.decref` | v1 (B4) | unmoved owned bindings at scope end |
| `eco.free` | v1 (B5) | `DropFree`: statically-unique drops (§14.3) |
| `eco.decref_shallow` | v2 (arrays) | child-decref walk lands with per-tag layout traversal |
| `eco.reset` / `eco.reset_ref` | post-v2 | Perceus reuse — explicitly out of scope; RC-1 mutation (§17) is the reuse story instead, per the paper (§6.7: reuse deliberately unimplemented; RC-1 + drop-sliding covers it) |

The north star is **RC-1 optimistic mutation** (§17): at a mutating
primitive, check the header count; 1 ⇒ mutate in place, else
copy-on-write. Borrow inference's contribution is *honest counts* — with
transient dups elided, count 1 means genuine sole ownership (the paper's
`map_rec`: a fold accumulator stays at 1 through every iteration,
guaranteeing in-place push). The full soundness conditions are §17
(S1–S6); the hybrid RC-under-tracing-GC model is §16 (RC as accelerator,
GC as collector of record; overcounts safe, undercounts unsound —
RC_001).

## 5. Sharing implementation with LSS (Q5)

### 5.1 Same shape, different substrate

The two analyses share their *shape*: interprocedural,
signature-per-unit, SCC-granular fixpoints, optimistic initialization
raised monotonically, a total ⊤/poison fallback, and census-gated
rollout. They do **not** share a substrate:

| | LSS | Borrow |
|---|---|---|
| Lattice carrier | solver-store `Point` content (`MonoSolver/Store.elm` over `Type.UnionFind`) | pass-internal arrays indexed by DSU root |
| Join mechanism | **unification** (`unifySlotWithSet`, `poisonArrowSets`) | **directed** `≥` propagation on a worklist; flows must never be unified (DS1) |
| When | inside mono, demand-lazy, memoized per `TOpt.Cycle` | after GlobalOpt P5, whole-graph, reverse-topological SCC order |
| Fixpoint driver | fixpoint-by-unification (no worklist at all) | explicit monotone worklist over finite lattices |
| Units | front-end `TOpt.Cycle` nodes | `Compiler.Graph` SCCs over SpecId call edges |

Attempting to host borrow's directed lattice inside the solver store
would repeat v0's mistake (DS1); attempting to run LSS post-mono is
impossible (its inputs are gone). Verdict on Q5: **share utilities and
disciplines; keep the engines separate.** The advantage of sharing at
that level is real but bounded: roughly 40–50% of the pass *skeleton*
pre-exists; the core solver is all new code.

### 5.2 What must NOT be shared

- `Compiler.Type.UnionFind` / `System.TypeCheck.IO` — payload hard-wired
  to the type-checker `Descriptor`, `Point`-keyed, IO-threaded (DS1).
- `Compiler.MonoSolver.Store` and LssInfer's slot machinery — the LSS
  lattice literally lives inside solver descriptors.
- The `Engine.S` `Step` monad — drags in the whole 20+-field solver
  state.
- LssInfer's `TOpt.Cycle` unit granularity — pre-mono; borrow sees
  SpecId-level recursion and must use the mono call graph.

### 5.3 The reuse inventory

Directly reusable as-is:

- `Compiler.Graph.stronglyConnCompInt` (`Graph.elm:38`) — the mandated
  stack-safe Kosaraju (explicit stacks + BitSet; written because library
  SCC blew the stack on this very graph).
- `Compiler.Data.BitSet` for SpecId sets.
- The census pattern (§13): pass returns `(graph, BorrowStats)`;
  `GlobalOptStats` gains a nested field; `runGlobalOptPhase` prints one
  gated stderr line; flag in `Config.elm` + `ECO_BORROW_REPORT` env
  override, excluded from the config hash (output-only).
- `FEStats.withPhase` timing (borrow lives inside `PhaseGlobalOpt`).

Copy-the-core (small, deliberate duplication):

- `Compiler/GlobalOpt/Staging/UnionFind.elm`'s `ufFind` (path
  compression, `:110-134`) + `ufUnion` (`:139-153`) over
  `{ parent : Array Int }` — extracted into `Borrow/Dsu.elm` with Int
  keys, union-by-rank, and a tail-safe find (~80 lines). `ufUnion` is
  unexported and its wrapper is StagingGraph-coupled, so copying beats
  importing.
- `MonoInlineSimplify.buildCallGraph` (`MonoInlineSimplify.elm:1057-1210`)
  — the SpecId dense-indexing scaffold over `MonoGraph.callEdges` +
  `stronglyConnCompInt`. It currently discards the SCC list (keeps only
  `isRecursive`); borrow copies the scaffold and keeps the SCC list in
  reverse topological order. Caveat: `callEdges` is mono-time truth that
  the inline pre-pass and GlobalOpt wrapper insertion may have staled —
  borrow re-collects edges with one cheap fold over the final bodies
  (§11.1).
- `AbiCloning.instanceMember`'s member-keying logic (`AbiCloning.elm:
  488-504`: prefer `ClosureInfo.lssMember`, fall back `srcLambda`,
  adoption blocks) — reused by the §10.2 index build. Whether to extract
  a shared `LssIndex` helper module or duplicate ~15 lines is a B3.5
  engineering call; the *semantics* are fixed here either way.

Disciplines (patterns, not code):

- Memoized per-unit signatures with a re-entry guard and a total
  poison-on-mismatch fallback (LssInfer).
- AbiCloning's scale lesson (`AbiCloning.elm:31-39`, verbatim wording at
  `:626-635`): generic
  `MonoTraverse` combinators are ruinous for full-graph *rewrite* passes
  at 10⁵-node scale — use first-order direct recursion with an
  allocation-free early-exit pre-scan. Borrow's constraint walk needs an
  environment anyway (MonoTraverse has no binder-scoped visitor), so it
  hand-rolls; `MonoTraverse.foldExpr` remains fine for one-shot censuses
  and the call-edge collection fold.
- The A/B + byte-gate rollout discipline (§19).

---

# Part II — The analysis

## 6. Module map and configuration

New modules under `compiler/src/Compiler/GlobalOpt/Borrow/` (line budgets
are targets, not caps):

| Module | Role | ~LoC |
|---|---|---|
| `Borrow.elm` | Phase-6 driver: edge collection, SCCs, per-def orchestration, stats | 250 |
| `Borrow/Rty.elm` | `RTy`, `freshRTy`, `zipRTy`, heap-position rules, `rcManaged` | 150 |
| `Borrow/Lifetime.elm` | paths, `Life`, `Lifetime`, `join`/`leq`/`endsBefore`/`onBoundary` | 200 |
| `Borrow/Dsu.elm` | Int union-find (path compression + rank) | 80 |
| `Borrow/Constrain.elm` | per-def constraint generation (§8) | 350 |
| `Borrow/Solve.elm` | staged fixpoints A–D (§9) | 300 |
| `Borrow/Sig.elm` | `BorrowSig`, SCC fixpoint, signature readback (§11) | 200 |
| `Borrow/KernelSigs.elm` | audited kernel table (§12) | 120 |
| `Borrow/LssFacts.elm` | LSet/srcLambda query API (§10) — B3.5 | 200 |
| `Borrow/Check.elm` | post-reification linearity checker (§19.3) — B4 | 150 |

Configuration (`Compiler/Eco/Config.elm`, decoded from `eco-config.json`
with env overrides, following the `lss`/`inline` blocks):

```elm
type alias BorrowConfig =
    { enabled : Bool          -- run the analysis (default False until B2 ships its gates)
    , reify : BorrowReify     -- ROff (analysis/census only) | RRc (emit RC ops)
    , report : Bool           -- census line on stderr; env ECO_BORROW_REPORT
    , validate : Bool         -- run Borrow/Check after reification
    }
```

`enabled = False` is byte-identical by construction (the pass is not
called). `reify = ROff` is *graph*-identical (analysis only; stats out).
`report`/`validate` are excluded from the config hash (output-only), like
`lss.report`. The ecoc driver passes `--rc-mode` to the backend iff
`reify = RRc` (§15.2).

## 7. Analysis data model

### 7.1 Resource variables — two index spaces, one variable set

`type alias ResVar = Int` — dense, minted per heap position per
def-analysis. ONE ResVar per heap position, not two: the paper tracks
`storage(𝔯)` and `access(𝔯)` as two lattice maps over one variable set
(Fig. 7's `primary` marker records which becomes the reified mode).
Mirrored here with **two distinct index spaces**, and the distinction is
load-bearing:

- **Storage** is an equivalence: `Borrow/Dsu.elm` quotients ResVars
  along `storageEq` AND flow edges (the paper's storage rules are a
  bidirectional ≥ pair, i.e. equality along every flow — §3.3's
  nested-rc lock). Each DSU class carries one `storageOwned` bit.
- **Access modes and lifetimes are directed, per-ResVar quantities**:
  `access : Array Mode`, `ltA/ltP : Array Lifetime` are indexed by **raw
  ResVar**, and flow edges stay directed `(bind, use)` pairs of raw
  ResVars. They are NEVER quotiented by the storage DSU — collapsing
  bind and use into one cell would make every flow edge a self-loop and
  destroy the ability to say "borrowed use of an owned binding", which
  is the entire point of the pass (this is v0's unification mistake in a
  new coat; DS1 applies to the storage DSU too).

The reified mode of each resource combines the two maps via the primary
rule (§9.5).

### 7.2 Heap positions of a `MonoType`

From `Monomorphized.elm:202-214` and the representation invariants (only
Int/Float/Char are unboxed in heap fields; Bool/Unit are embedded
HPointer constants, never allocated — REP_CONSTANT_001, HEAP_010):

| MonoType | Carries a resource? | Notes |
|---|---|---|
| `MInt`/`MFloat`/`MChar`/`MBool`/`MUnit` | no | scalars/embedded constants; never RC'd (BORROW_001) |
| `MString` | yes | flat-buffer family; prime `rcManaged` candidate (DS6) |
| `MList t` | yes (spine) + element resources | spine collapse per §7.3 |
| `MTuple`/`MRecord` | yes + per-field | |
| `MCustom home name args` | yes + per-type-arg | interior beyond args collapsed (§7.3) |
| `MFunction …` | yes (closure env) | param/result spaces handled at boundaries only |
| `MVar _ CEcoValue` | yes | erased opaque box; interior unknown ⇒ poisoned (`RErased`) |

### 7.3 `RTy` — the annotated type (pass-internal)

```elm
type RTy
    = RScalar
    | RString ResVar
    | ROpaque ResVar                      -- MVar _ CEcoValue
    | RList ResVar RTy
    | RTuple ResVar (List RTy)
    | RRecord ResVar (List ( Name, RTy )) -- sorted field order
    | RCustom ResVar (List RTy)           -- type-arg positions only
    | RClosure ResVar                     -- env resource
```

`freshRTy : Mono.MonoType -> Gen -> ( RTy, Gen )` mints one ResVar per
row; `zipRTy : RTy -> RTy -> List ( ResVar, ResVar )` structurally pairs
ground shapes (always aligned — the types are ground and equal by
construction at every pairing site).

**`RCustom` interior collapse.** The paper's recursive-type rule already
collapses all same-μ nested occurrences onto one mode (paper §5.2:
guardedness makes the top-level mode a statement about all nested
occurrences). v1 extends the collapse to ALL non-type-arg interior of a
custom: any projection out of a custom whose projected type is heap-typed
merges its storage class with the custom's own class and relates access
modes by the vertical (get) rules. Per-ctor field precision (via
`MonoGraph.ctorShapes`) is a v2 refinement with the same constraint
shapes (§22.4).

**`ROpaque` poisoning.** An erased value's interior is unknowable;
resources reaching or leaving an `ROpaque` are `forcedOwned RErased`.
The census counts them (`poisonedByErased`).

### 7.4 Lifetimes: paths, trees, and the skeleton

`Borrow/Lifetime.elm`; the paper's structural lifetimes (§4.1)
specialized to Mono expression skeletons:

```elm
type Step
    = Seq Int Int      -- sequential child i of n (evaluation order)
    | Arm Int Int      -- alternative arm i of n (disjoint executions)

type alias Path = List Step   -- root-relative, function-local

type Life
    = Star                    -- ends exactly here            (paper ★)
    | InSeq Int Int Life      -- ends within sequential child (paper ↙/↘, n-ary)
    | InAlts Int (Dict Int Life)  -- per-arm ends; missing arm = (— ∥ ℓ)

type Lifetime
    = LEmpty                  -- unused (⊥, paper ∅)
    | LLocal Life
    | LParams (Set Int)       -- ⊔ of param-position lifetime vars α (paper §5.1);
                              -- ordered after every LLocal
```

`join` (⊔): `LEmpty` is ⊥; `LParams s ⊔ LParams t = LParams (s ∪ t)`;
`LLocal _ ⊔ LParams s = LParams s`; on `LLocal`,
`InSeq i _ ⊔ InSeq j _` keeps the LATER index (recurse on tie), and
`InAlts ⊔ InAlts` joins pointwise per arm. Predicates:
`leq` (every branch of L covered by L′), `endsBefore : Lifetime -> Path
-> Bool` (the paper's `L ≺ p` — no branch of L contains p; the value is
dead at p) and `onBoundary` (`L ≍ p` — p coincides with a final
occurrence). These orderings are subtle (the paper warns `L ≺ p` is not
`¬(p ≤ L)`); B1 property-tests them on randomized skeletons (§19.1).

### 7.5 Constraints and occurrences

`Borrow/Constrain.elm` accumulates:

```elm
type alias Constraints =
    { flows : List ( ResVar, ResVar )        -- bind → use (lateral; paper I-Use)
    , gets : List Get                        -- container reads (paper I-Get)
    , storageEq : List ( ResVar, ResVar )    -- nested/heap-storage equalities (paper §3.3)
    , scopes : Dict ResVar Path              -- binding resource → scope path (I-Let)
    , seeds : List ( ResVar, Path )          -- ltA/ltP ≥ p (reads, borrowed-call args)
    , forcedOwned : List ( ResVar, Reason )
    , occs : List Occ                        -- reification records
    }

type alias Get =
    { container : ResVar
    , out : List ( ResVar, ResVar )   -- (containerInterior, projected): vertical-flow candidates
    , path : Path
    }

type alias Occ =
    { occId : Int, binder : Name, path : Path, res : List ResVar }

type Reason
    = RConstruct | RKernel | RClosureBoundary | RErased | RPort | RTailArg
```

## 8. Constraint generation

### 8.1 Walker shape

Direct recursion in the Design-B style (no DSL, no generic combinators —
the AbiCloning scale lesson, §5.3), threading:

```elm
type alias Env =
    { vars : Dict Name RTy                    -- binding → its RTy
    , sigs : SpecId -> Maybe BorrowSig        -- current signature table (§11)
    , kernels : ( Name, Name ) -> KernelSig   -- §12; total via all-owned default
    , lssFacts : LssFacts.Facts               -- §10; Facts.empty pre-B3.5
    }

constrainExpr : Env -> Path -> Mono.MonoExpr -> Gen -> ( RTy, Gen )
```

`Gen` threads the ResVar supply and accumulating `Constraints`. Every
`MonoExpr` carries its `MonoType` (`Mono.typeOf`), so `freshRTy` is
always available for result/boundary minting. Expression walks by direct
structural recursion are accepted practice (depth = AST depth); the
fixpoint/worklist dimension never goes through the call stack
(stack-safety idiom, `plans/state-monad-stack-safety.md`).

### 8.2 Per-constructor rules

| Constructor | Constraints emitted |
|---|---|
| `MonoLiteral (LStr _)` | fresh `RString r`, marked `immortal` (interned literals; census only, reify skips) |
| other `MonoLiteral` | `RScalar` |
| `MonoVarLocal x` | look up binding RTy; mint use RTy; `flows` bind→use pairwise (`zipRTy`); `storageEq` on all *nested* pairs (heap-storage rule, paper §3.3); record `Occ` |
| `MonoVarGlobal _ specId` | zero-arity value: call rule (§8.3) with 0 args; function reference: fresh `RClosure` |
| `MonoVarKernel …` | kernel *value* (not call): fresh `RClosure`, boundary-poisoned |
| `MonoList` / `MonoTupleCreate` / `MonoRecordCreate` | constrain elements; result fresh; element-use resources `storageEq` with the container's slot resources; container top `forcedOwned RConstruct` (paper I-Rc). Element occurrences are **heap-store positions**: their access is forced Owned via the Stage-C store obligation (§9.5), so a Borrowed binder stored here gets a coercion dup — never zero RC ops |
| `MonoRecordUpdate base fields` | constrain base (a read: `gets` at this path) + fields; result fresh `forcedOwned RConstruct`; copied-over fields = vertical `Get.out` pairs base→result (new references to old field values) |
| `MonoRecordAccess e f` | constrain `e`; `gets { container = top e, out = [(slot f, fresh)], path }`; `seeds` on container top |
| `MonoDestruct (MonoDestructor x dpath) body` | root's resource `seeds` at `Seq 0 2`; `gets` with `out` per projected heap position; bind `x`; body at `Seq 1 2`; `scopes` for `x` = `Seq 1 2` |
| `MonoCase root _ decider jumps` | decider tests `seeds` the root's resource chain (tests read tags/fields); each arm at `Arm i n`; arm results zipped to a fresh case-result RTy (`flows` both directions ⇒ effectively `storageEq` + access joins — the paper's branch unification) |
| `MonoIf pairs else` | conds/branches per skeleton; branch results zip as for case |
| `MonoLet (MonoDef x rhs) body` | rhs at `Seq 0 2`; bind `x`; `scopes (res x) = Seq 1 2`; body |
| `MonoLet (MonoTailDef …) body` | local tail function: analyzed as a nested def (own skeleton); signature all-owned v1 |
| `MonoCall f args _ callInfo` | §8.3 |
| `MonoTailCall _ args` | args constrained; every arg occurrence seeds **escape** (§8.5) + flows into the SCC signature params |
| `MonoClosure info body` | §8.4 |
| `MonoAccessorValue` | function value → boundary-poisoned `RClosure` |
| `MonoUnit` | `RScalar` |

`MonoNode` kinds: `MonoDefine`/`MonoTailFunc` are the per-def entry
points; `MonoCtor`/`MonoEnum` get the construct rule;
`MonoExtern`/`MonoManagerLeaf`/`MonoPortIncoming`/`MonoPortOutgoing`
poison their whole signature (`RPort`), matching LSS's port/kernel
boundary treatment.

### 8.3 Call boundaries

Dispatch on the callee expression + `callInfo.callKind`:

- **Direct call to `MonoVarGlobal specId`** (`CallDirectFlat` /
  `CallDirectKnownSegmentation`, single-stage saturated): fetch
  `BorrowSig` for `specId` (§11). Zip each arg RTy against the sig's
  param RTy:
  - param **Owned** → the arg occurrence is an owned use: `flows`
    bind→param-instance, nested `storageEq`;
  - param **Borrowed** → the arg must be live for the call:
    `seeds (argRes, callPath)`; no ownership transfer.
  - Result: `freshRTy`; for each result resource whose sig lifetime is
    `LParams s`, add `flows argRes → resultRes` for every param position
    in `s` — the paper's §5.1 argument–return coupling, which lets the
    caller's lifetime propagation see through the call.
- **Kernel call** (callee `MonoVarKernel`): same shape with `KernelSig`
  from `Borrow/KernelSigs.elm` (§12). The all-owned default is the
  Perceus baseline for that call.
- **Closure/generic** (`CallGenericApply`, `CallSegmentationUnknown`,
  multi-stage PAP chains): consult `LssFacts.query` (§10.3).
  - `Routed sig` → proceed exactly as a direct call against `sig`.
  - `Poison` (the only possible answer pre-B3.5 and under `EngineSubst`)
    → every arg `forcedOwned RClosureBoundary`, result fresh all-owned.
    Census: `poisonedByClosure`, and per §10.3 the poison *cause* split.
- **Under/over-application** (PAP creation): captured args are stores
  into a PAP heap object → same as closure capture: `forcedOwned`.

### 8.4 Closures and captures

`MonoClosure info body`: captures are stores into a heap closure
environment. v1 rule: each captured heap resource is
`forcedOwned RClosureBoundary` (the env's lifetime is unknown to local
analysis), nested `storageEq` with the env interior; the body is analyzed
as a nested function. Pre-B3.5 the body's params/result are all-owned;
from B3.5 the body gets its own optimistically-initialized signature
registered under its `lambdaId` (§10.4) so singleton call sites can route
to it. **Captures stay owned even in B3.5** — capture borrowing requires
proving closure-lifetime ≤ capture-lifetime, which is v2 work (§22.7);
the census (`capturesForcedOwned`) sizes it.

### 8.5 Tail calls

Per the paper §6.3, and it is subtle: forcing tail-call argument *modes*
to owned is the WRONG (too strong) encoding. Instead their occurrences
are treated as **escaping during ltA** — each arg resource is seeded with
a path ordered after the whole body — which still admits borrows that
originate outside the call-graph SCC while preventing reification from
ever placing a drop after the tail call (which would break TCE in the
backend's `MonoTailCall`/`MonoTailFunc` loop emission); drops for
unrelated owned temps whose scope ends beyond the call are hoisted to
just before it (§14.2). BORROW_005 pins both with a TestLogic check.
Note `MonoTailCall`'s callee is a *name* of a loop target, never an
expression — a generic apply in tail position is an ordinary `MonoCall`
that returns normally, so LssFacts routing can never interact with
BORROW_005.

## 9. Solving

`Borrow/Solve.elm` — four stages, strictly ordered. The ordering is
load-bearing: the paper proves approximate and precise lifetimes are
**incomparable** (precise can be shorter — a dup/move cuts lateral flow —
and longer — vertical flow through gets on owned content), so reusing
ltA for drop placement is unsound (paper §4.4). All stages are monotone
one-step operators over finite lattices (Knaster–Tarski); optimistic
initialization (`&`, `LEmpty`) raised monotonically, never lowered.

- **Stage A — storage classes.** Union in the DSU: all `storageEq` pairs
  AND all `flows` pairs (the paper's storage rules are a bidirectional ≥
  pair, i.e. equality along every flow edge — §3.3's nested-rc equality:
  never `& rc (& rc t)` from an owned-of-owned). Each class carries one
  `storageOwned` bit, set by `forcedOwned` members. The DSU is the
  storage quotient ONLY — Stages B–D operate on raw ResVars (§7.1).
- **Stage B — approximate lifetimes (ltA).** Seeds from `seeds`;
  propagate along directed `flows` edges in the **bind ≥ use** direction
  under the paper's mode-oblivious pessimistic derivation assumption.
  Worklist of ResVars: pop `u`; for each bind `b` with `flow(b,u)`:
  `new = join (ltA b) (ltA u)`; if changed, set and push `b`. Terminates:
  finite lattice, height bounded by expression branching depth.
- **Stage C — access modes.** Lattice `& < •`, per raw ResVar. For every
  directed flow edge `(b,u)`: `access b := access b ⊔ access u` (owned
  occurrence ⇒ owned binding — the paper's rule (2), which converts
  would-be `dup(&x)` into moves and is what propagates ownedness *down*
  into mutator arguments, §17 H4); and if
  `not (endsBefore (ltA u) (scope b))` — the occurrence escapes the
  binding's scope — then `access u := access u ⊔ access b` (rule (1):
  escape from an owned binding must be owned, else use-after-free).
  `forcedOwned` resources start Owned; `gets` impose
  `access interior = access projected` (paper get-constr); and every
  resource at a **heap-store position** whose storage class is
  owned-storing has its access forced Owned (the I-Rc store obligation —
  §9.5's coupling; this is what makes storing a borrowed binding into a
  container demand a coercion dup rather than silently emitting
  nothing). Iterate to fixpoint (two-point lattice ⇒ at most 2 passes
  per edge in practice).
- **Stage D — precise lifetimes (ltP).** Same seeds; propagate along
  **lateral-flow** — flow edges whose use side solved Borrowed — and
  **vertical-flow** — `Get.out` pairs where the container interior is
  Owned and the projected value Borrowed (the get's output borrows the
  container, so the container must outlive it). ltP governs move
  legality and drop placement (§14.2).

### 9.5 Reified modes: the primary rule and coercion points

The paper's `primary` marker (its Fig. 7), stated for eco:

- The reified mode of a **top-level** resource of a binding or
  occurrence is its solved **access** mode.
- The reified mode of a **nested** (heap-interior) resource is its
  **storage** class: `storageOwned` ⇒ owned. (The storage mode of a
  top-level resource and the access mode of a nested one exist during
  solving but are not reified.)

**Coercion points.** A position where the *producer's* mode is Borrowed
but the *consumer-side* solved mode is Owned is a **borrow→owned
coercion**, and reification MUST insert a dup there (§14.2) — this is
the paper's dup-completion, and it is what makes the analysis total.
The coercion positions are: call results whose signature mode is
Borrowed (including §10.3's merged-Borrowed meets and `resultAliases`
kernel results and `OriginAccessor` routes) consumed at an
owned-demanding position; projections (`Get.out`) whose output must be
owned; and heap-store operands whose binder solved Borrowed (Stage C's
store obligation above). Without these dups the count under-represents
live references — RC_001's unsound direction; §19.3's checker verifies
every owned-demanding position is fed by a move, a dup, or an
owned-fresh producer.

**Complexity.** Per def: minting O(type sizes), edges O(occurrences ×
type width), each fixpoint O(edges × lattice height). Whole-program: the
SCC iteration count is bounded by the longest mode/lifetime-set chain in
any signature — 2–3 in practice. Budget: ≤3% self-compile wall at B3
(§21); elm-aws-codegen is the pathological-input canary (deep inliner let
chains — the annotateCallStaging incident's lesson).

## 10. The LSS facts channel: `Borrow/LssFacts.elm` (Q4)

This section answers Q4 in full: how "where LSS knows a singleton, borrow
routes through the member's real signature instead of poisoning"
actually works.

### 10.1 What survives post-mono — and what does not

Facts available on the graph at Phase 6 (all verified):

1. **`LambdaSetAnno` on every `MFunction` arrow**
   (`Monomorphized.elm:214,262-264`): `LTop | LSet (List Int)`,
   non-empty ascending member ids (LSS_001). Survives everywhere types
   survive, including `registry.reverseMapping` stored types. Read via
   `headAnno` (`:409`) / `singletonHeadMember` (`:538`).
2. **`ClosureInfo` on every `MonoClosure`** (`:952-960`):
   `lssMember : Maybe Int` — the Fix-B spec-qualified member id this
   instance was minted under (LSS_017); `srcLambda : Maybe SrcLambdaId` —
   source identity, shared by inliner copies (MONO_019); plus captures
   and params with types.
3. **The AbiCloning stamps on `CallInfo`** (post-P4/P5, `:1538-1550`):
   `fastEvaluator : Maybe LambdaId`, `captureAbi`, `closureKind = Known…`,
   `fastPapPrefix` — each one a P4-*verified* singleton-instance fact
   (the guard ladder passed: layout fingerprint, eqLayout, capture
   unanimity).
4. `MonoGraph.callEdges`, `specHasEffects`, `specValueUsed`,
   `registry.reverseMapping`.

**What does NOT survive:** the LSS member interning table and — crucially
— the member→Global and member→kernel **reverse maps**
(`Engine.LssMemberTable.{globals,kernels}`, `Engine.elm:128-137`). They
die with engine `S` at mono exit (`assembleRawGraph`,
`MonoSolver/Monomorphize.elm:927-996`, copies only
nodes/registry/ports/counters + derived sets). This is exactly why the
E9/E9.2 devirtualization runs *inside* mono. Consequence: post-mono, a
standalone member id (`g|` global, `c|` ctor, `k|` kernel, `a|`
accessor) appearing in an `LSet` is an **opaque integer** — only lambda
members are resolvable, via `ClosureInfo.lssMember` instances.

### 10.2 The new export: `MonoGraph.lssMemberOrigins`

To let borrow route standalone members, mono exports a compact reverse
map that today it discards:

```elm
-- Compiler/AST/Monomorphized.elm
type MemberOrigin
    = OriginGlobal TOpt.Global    -- g| members (E9.2 kernel-alias folds already resolve to k|)
    | OriginKernel Name Name      -- k| members (home, name)
    | OriginCtor TOpt.Global      -- c| members
    | OriginAccessor Name         -- a| members

-- MonoGraph gains:
--   , lssMemberOrigins : Dict Int MemberOrigin
```

Populated by `assembleRawGraph` from `s.lssMemberTable.globals/kernels`
plus the ctor/accessor intern keys, just before engine state is dropped.
Under `EngineSubst` (or LSS off) it is `Dict.empty` — the inert path.
Size is a few thousand entries (member ids are interned, not per-site).
`MonoGraph` goes from 10 fields to 11 — nowhere near the native 32-slot
record scan cap that constrains `Engine.S`. To translate an
`OriginGlobal` to a `SpecId` (for `BorrowSig` lookup), the driver builds
a one-shot `Global → SpecId` index from `registry.reverseMapping` at
Phase-6 start.

Alternative considered and rejected: re-deriving origins from graph shape
(fragile — exactly the kind of positional reconstruction the Fix-B
postmortem warns about), or stamping borrow facts in-mono like E9 devirt
does (couples borrow to mono timing; contradicts DS8).

### 10.3 The query and its decline ladder

```elm
type CalleeFacts
    = Routed BorrowSig            -- proceed as a direct call against this sig
    | Poison PoisonCause          -- all-owned boundary; cause feeds the census

type PoisonCause
    = PTop            -- headAnno = LTop (incl. every IO-continuation ⊤-by-soundness site)
    | PBlocked        -- a member's instance set is blocked (adoption/wrapper, LSS_008)
    | PUnresolved     -- standalone member with no origins entry (pre-export or stale)
    | PNoSig          -- resolvable, but the target's sig isn't computable this round
    | PMixedMeet      -- members' sigs disagree beyond the sound meet (census detail)

query : Facts -> Mono.CallInfo -> Mono.MonoType {- callee type -} -> CalleeFacts
```

Resolution order at a generic/unknown call site:

1. **Stamp shortcut.** If `callInfo.fastEvaluator = Just lambdaId`
   (AbiCloning stamped this site), route directly to that instance's
   lambda signature (§10.4) — the stamp already survived P4's guard
   ladder, which is strictly stronger than what borrow needs. PAP-suffix
   stamps (`fastPapPrefix = Just k`, LSS_011) zip the supplied args
   against the sig's param *suffix* after the k prefix positions — the
   prefix params were captured at PAP creation and already forced owned
   through the capture channel (§8.4). Note the converse does *not*
   hold: AbiCloning declines for ABI reasons (charFree, capture
   disunity, arity) that are irrelevant to borrow — borrow needs only
   the body, not an ABI match — so step 2 recovers sites AbiCloning
   declined.
2. **Set resolution.** `headAnno (typeOf callee)`:
   - `LTop` → `Poison PTop`.
   - `LSet ms` → resolve each member `m`:
     * **lambda member**: look up the instance index (§10.4). Blocked
       (adoption/staging-wrapper per LSS_008 semantics) → the member's
       behavior set is not enumerated by its instances → `Poison
       PBlocked`. Otherwise take the meet of the instances' lambda sigs
       (LSS_009/017 make verbatim instances interchangeable, so the meet
       should be trivial; `validate` asserts sig-equality across
       instances as a cheap soundness probe).
     * **standalone member**: `lssMemberOrigins`:
       `OriginKernel` → `KernelSigs.lookup`; `OriginGlobal` →
       `BorrowSig` of the mapped SpecId; `OriginCtor` → the construct
       sig (all params owned-stored, result owned-fresh);
       `OriginAccessor f` → the borrow-through sig
       (param borrowed, result `LParams {0}`). Missing entry →
       `Poison PUnresolved`.
   - Multi-member sets meet pointwise (below).
3. **The meet, and its soundness direction.** Following RC_001's
   asymmetry (undercount is the unsound direction; leaks are reclaimed by
   the tracing backstop):
   - **Params: any-owned wins.** If any member takes a param owned, the
     merged sig takes it owned — the caller dups/moves, which is always
     sound: the member that would only have borrowed it simply never
     drops the transferred unit (count too HIGH, GC backstop; an
     inflated count can only make RC-1 fail conservatively).
   - **Results: any-borrowed wins.** If any member returns a borrow, the
     merged result is Borrowed with the *union* of the members'
     `LParams` sets. A Borrowed result is not exempt from accounting —
     if the caller's use of it solves Owned (it stores or returns it),
     §9.5's coercion rule inserts a dup at the result, so a
     member-that-aliased result gains a counted unit before any owned
     use and a member-that-owned result gains one more than needed (the
     original unit leaks — safe direction). The caller never *drops the
     result binding itself* (no owned unit was conferred by the sig);
     all owned obligations enter via coercion dups. Sites degraded this
     way bump `PMixedMeet` in the census.
   - **The merged sig is a call-site-only artifact.** Member bodies are
     always analyzed and compiled against their own true signatures;
     merged sigs must never be cached into `lambdaSigs` or `sigs` — the
     params-direction argument above depends on it (BORROW_006).

This ladder is **total and monotone-safe**: every arm either routes to a
real signature or lands on the all-owned Perceus baseline. It is also
**stable** in the sense the question asks: member ids are interned mono
constants carried on the nodes themselves (`ClosureInfo.lssMember`
survives every GlobalOpt rewrite; inliner copies share `srcLambda`;
staging wrappers deliberately carry neither and therefore block), so the
facts cannot silently drift as passes rewrite the graph.

### 10.4 Lambda signatures and the instance index

Borrow builds its own member→instances index at Phase-6 start — the
AbiCloning scan (`collectInstances`, `AbiCloning.elm:235-247`) is the
template but is not reusable as-is for two reasons: its `Instance`
retains only types (no bodies), and it runs at P4 (bodies are rewritten
again by P5). The borrow index, built in the same single graph scan that
collects call edges:

```elm
type alias LambdaInstances =
    { byMember : Dict Int (List LambdaRef)   -- member id → instances
    , blocked : Set Int                       -- LSS_008 adoption/wrapper-blocked members
    }

type alias LambdaRef =
    { lambdaId : Mono.LambdaId
    , enclosingSpecId : SpecId    -- the def whose analysis solves this lambda's sig
    , closureInfo : Mono.ClosureInfo
    , body : Mono.MonoExpr
    }
```

Member keying reuses `instanceMember`'s exact semantics: prefer
`closureInfo.lssMember` (Fix B — the same id space as the annotations),
fall back to raw `srcLambda`, and let synthesized closures (both fields
`Nothing`) under a singleton head adopt-and-block.

**Where lambda sigs live in the fixpoint — and the ordering
obligation.** Closure bodies are nested in their enclosing defs, so they
are constrained during the enclosing def's analysis (§8.4); from B3.5
each indexed lambda additionally registers a `BorrowSig` in a
`lambdaSigs : Dict LambdaId BorrowSig` table, read back from the body's
solved param/result resources. A lambda's sig is only ever solved by its
**enclosing** def's SCC — but a *routed caller* can live in a different
SCC, and nothing in the plain call graph orders that caller after the
enclosing def. Without a fix, reverse-topological order can solve the
caller first against an optimistic (all-borrowed) lambda sig that later
strengthens, and the caller is never revisited — callers never dup an
arg the lambda stores: RC_001's unsound direction. Two-part fix, both
mandatory:

1. **Routed edges.** During §11.1's edge-collection scan (which builds
   the instance index in the same pass), every routable site — a
   `fastEvaluator` stamp or a resolvable singleton `LSet` — contributes
   a call-graph edge from the *caller's* def to the instance's
   `enclosingSpecId`. SCC formation then orders (or merges) routed
   callers with the defs that solve their callees' sigs, and the
   ordinary reverse-topological fixpoint covers them.
2. **The `PNoSig` gate as backstop.** A `lambdaSigs` read for a lambda
   whose enclosing SCC has not yet been solved answers
   `Poison PNoSig` — never the optimistic initialization. This catches
   anything edge collection missed; the census counts these (a nonzero
   steady-state count means the edge collection has a gap).

Routed call sites otherwise read `lambdaSigs` exactly like `sigs`.

### 10.5 What the handshake does and does not recover

It upgrades the **call boundary** (params/result) at every closure call
site whose set is a resolvable singleton (Run M measured 13.2% of
dispatch *events* fast-routed under the ABI-guarded flavor of this fact;
borrow's site coverage is a strict superset since the ABI guards don't
apply to it). It does **not**:
recover ⊤ sites (§1 — E8 territory); borrow captures (v1 keeps captures
owned, §8.4/§22.7); or improve subst-engine builds (§3.3). The B3.5
census quantifies each bucket (`poisonCause` split) so the v2 items are
sized with data, not hope.

## 11. Interprocedural signatures

### 11.1 Driver

`Borrow.run` (`Borrow.elm`):

1. **Edge collection**: one fold over the final bodies collecting
   `MonoVarGlobal` SpecIds per def, plus — from B3.5, in the same scan
   that builds the instance index — a **routed edge**
   caller-def → `enclosingSpecId` for every stamp or resolvable
   singleton-`LSet` site (§10.4's ordering obligation).
   `MonoGraph.callEdges` is mono-time truth that the inline pre-pass and
   GlobalOpt wrapper insertion may have staled; one cheap re-collecting
   fold beats trusting it.
2. **SCCs**: dense-index live SpecIds (the `buildCallGraph` scaffold,
   copied — §5.3) → `Compiler.Graph.stronglyConnCompInt` → process SCCs
   in **reverse topological order** (callees first).
3. **Per SCC**: initialize member sigs optimistically (params Borrowed
   with fresh α, results `LParams ∅`); run §8 + §9 per member; read back
   sigs from solved param/result resources; repeat until stable. Modes
   only ever go `& → •` and lifetime sets only grow ⇒ monotone on finite
   lattices ⇒ terminates. Acyclic SCCs solve in one iteration.
4. Stats out; if `reify = RRc`, run §14's wrap pass; if `validate`, run
   §19.3's checker.

```elm
type alias BorrowSig =
    { params : List SigTy            -- RTy shape + solved Mode per position
    , result : SigTy
    , resultLts : List ( ResPos, Set Int )   -- result position → LParams set
    }
```

### 11.2 v1: one signature per SpecId — measured poisoning

A single ownership-demanding call site drags a param to Owned for all
callers (the paper's §6.2 poisoning example). v1 accepts this and
**counts** it: for each param forced Owned, the census records how many
call sites demanded Owned vs would have accepted Borrowed
(`poisonedParams`, `poisoningCallSites`) — directly sizing v2's mode
specialization before any cloning code is written. v2 rides the
now-shipped keyed-specialization/AbiCloning substrate, with the paper's
§6.2 advice (merge specializations with identical induced RC behavior —
their primes_sieve measured ±7% noise from unmerged identical copies).

## 12. Kernel borrow signatures

### 12.1 The table

~322 C-linkage kernel functions (413 CSV entries,
`design_docs/elm_kernel_functions.csv`); calling convention `HPtr` (u64
HPointer word) with `_Int/_Float/_Char` unboxed suffix instances
(`KernelAbi.suffixSelectingKernels`).

```elm
-- Borrow/KernelSigs.elm
type ParamMode
    = PBorrowed        -- reads only; never stores or returns-by-identity
    | POwned           -- default; may store, return, or hand to unknown code

type alias KernelSig =
    { params : List ParamMode
    , resultAliases : Maybe Int   -- Just i: result may alias param i (borrow-through)
    }

lookup : ( Name, Name ) -> KernelSig   -- total: unlisted ⇒ all POwned, resultAliases = Nothing
```

Keyed by `(home, name)` exactly as `KernelTypeEnv`. The all-owned default
is the Perceus baseline — sound without any audit.

### 12.2 The v1 audited allowlist

Audit criterion per entry, verified against the `elm-kernel-cpp`
implementation before listing: *reads argument heap data; does not store
the argument or any interior pointer into a result or global; result
shares no identity with the argument unless declared via
`resultAliases`.* Initial entries (the paper's Perceus-fairness spirit):
`Utils.{equal,notEqual,compare,lt,le,gt,ge}`, `List.length`,
`String.{length,isEmpty,startsWith,endsWith,contains}`,
`JsArray.{length,unsafeGet}` (`unsafeGet` with `resultAliases = Just 0`),
`Basics.*` numeric ops (scalar-anyway), `Debug.{log,toString}`,
`Console.write`-family sinks. Growing the list is cheap, per-entry,
independently testable — each upgrade is pure RC-op savings.

### 12.3 Kernel counting obligations (RC mode)

Before a type enters `rcManaged`, every kernel that can create a
*surviving* reference to a value of that type must inc it (§17 S1). For
the v1 pointer-free-buffer scope this set is small and
byte/string-local: the `Bytes` codecs, the string builders/slicers
(views! — §17 S3's corollary: an *uncounted* `Tag_StringUtf8View`
excludes its backing from RC-1 mutation; the B0 report decides
count-at-view-creation vs exclusion per form), and
`Json.Encode.string`. The audit lands as a checklist in the B0 report —
the borrow-flavored twin of the MonoSolver kernel-honesty frontier
(solver-reuse-evaluation §6.3) — and is scheduled before B4, not before
the analysis milestones.

## 13. Census: the analysis-only deliverable

The B2/B3/B3.5 census (`ECO_BORROW_REPORT=1`, one stderr `key=value`
line per the house pattern) is a first-class deliverable — it is the
evidence for every later milestone's go/no-go:

- Per-def and aggregate: resources minted, %borrowed, would-be
  dups/drops/frees (RC ops that *would* be emitted under `reify=rc`).
- Poisoning: `poisonedByClosure` (with `PoisonCause` split from B3.5),
  `poisonedByErased`, `poisonedByKernel`, `poisonedParams` /
  `poisoningCallSites` (§11.2), `capturesForcedOwned` (§8.4).
- DS4 validation: `nonVarOperandHeapResults` — heap-typed non-variable
  operands, split by producer mode (owned-fresh vs borrowed-producer:
  the latter are §9.5 coercion candidates, the class DS4's argument must
  not lose).
- `updateCopiedHeapFields` — heap-typed copied-over fields in
  `MonoRecordUpdate` (no occurrence to attach a dup to; the counter that
  sizes the B6 field-selector prerequisite, §18).
- `lambdaSigNoSigReads` — `Poison PNoSig` answers from `lambdaSigs`
  (§10.4; nonzero steady state = routed-edge collection gap).
- RC-1 sizing (§17 C1): borrow lifetimes crossing owned mutator-argument
  flows (the paper's unify fallback class).
- Memory watch: max borrow-induced lifetime extension per def (the paper
  saw one +2.5% peak-footprint regression).
- `immortal` literal count; meet-degraded sites (`PMixedMeet`).

The dynamic twin (`ECO_RC_STATS`, B4) counts executed dups/drops at
runtime; census predictions and dynamic counters must reconcile (§19.2).

---

# Part III — The optimizations

*Everything in this part is gated behind `reify = RRc` and sequenced
after the analysis has shipped and its census has sized the payoff. It
is specified now so the analysis is provably sufficient for it — but
none of it constrains B1–B3.5.*

## 14. Reification to Mono RC constructors

### 14.1 New constructors

```elm
-- Compiler/AST/Monomorphized.elm
    | MonoRcDup Int MonoExpr      -- inc target's count by n, yield it
    | MonoRcDrop DropKind Name MonoExpr   -- drop binding at scope exit, yield body
type DropKind = DropDec | DropFree      -- DropFree: statically unique (B5)
```

Produced ONLY by Phase 6 (BORROW_002), never serialized; the 13
`MonoExpr`-matching files gain arms — 11 trivially (`Debug.todo`
"pre-Phase-6 pass observed RC op" — the BORROW_002 enforcement), MLIR
`Expr.elm`/`Ops.elm` non-trivially (§15.1).

### 14.2 Placement rules

From `Occ` records + solved modes + ltP (§9 Stage D):

- Owned occurrence, `onBoundary ltP path` (final use) → **move**: emit
  nothing.
- Owned occurrence, not final → wrap in `MonoRcDup 1`. Dups of one
  target coalesce into a single `$amount` batch ONLY when nothing at all
  intervenes between the coalesced occurrences (no call, no store, no
  other operation — not merely no other occurrence of the target), and
  the batch is always placed at the **first** coalesced occurrence —
  early overcount is RC_001's safe direction; late placement could let
  an intervening RC-1 check observe a count missing a live reference.
- **Coercion dup** (§9.5): a Borrowed-mode producer (borrowed-sig call
  result, `resultAliases` kernel result, accessor route, projection
  output) feeding an owned-demanding position → `MonoRcDup 1` at that
  point. This is the paper's dup-completion; it is not optional.
- Owned binding never moved → `MonoRcDrop` at its scope end
  (BORROW_004: the target is an in-scope let/param binding at the wrap
  point). If-arms insert compensating drops for asymmetric moves (the
  paper's BT-If merge). **Tail-call hoisting**: pending drops whose
  scope-end position would follow a `MonoTailCall` are emitted
  immediately *before* the tail call instead (BORROW_005). This is
  sound, not opportunistic sliding: §8.5's escape seeding forces any
  resource genuinely flowing into the tail args to be dup'd owned into
  them, which cuts its lateral ltP flow, so every remaining pending
  drop's ltP ends before the call.
- Borrowed anything else → nothing.
- `immortal` resources (interned literals, embedded constants) → nothing
  (RC_003 makes runtime helpers no-op on them anyway; skipping is a
  code-size courtesy).
- v1 places drops at scope end (with the mandatory tail-call hoisting
  above); ltP governs move legality and bounds every placement.
  Opportunistic drop-sliding — moving drops UP to the earliest
  ltP-permitted point to restore RC==1 sooner — remains v2 (§17 C1
  records the RC-1 cost of the deferral).

### 14.3 `DropFree`

Where the analysis proves zero dups reach a class on any path (§17 H3),
the drop is a `DropFree` → `eco.free` — no count check, no branch. B5
turns this on after the RC path itself has soaked.

## 15. MLIR and backend

### 15.1 Emission

`MonoRcDup n e` → constrain-emit `e`, then `eco.incref %v { amount = n }`;
`MonoRcDrop k x body` → emit body, then `eco.decref %x` /
`eco.free %x` at the insertion point. Zero-result ops with no regions —
cheap in both text and bytecode serialization.

### 15.2 `rcMode` gate

`EcoPipelineOptions` gains `bool rcMode` (default false; set from the
ecoc `--rc-mode` flag that the driver passes when `borrow.reify = rc`):

```cpp
// EcoPipeline.cpp — buildEcoToEcoPipeline
    if (!opts.rcMode)
        pm.addPass(eco::createRCEliminationPass());   // tracing mode: RC ops are a bug
    // rcMode: ops flow through untouched (no results, not GCRootCarriers)
    // and lower in EcoToLLVM (§15.3).
```

Tracing-mode behavior is preserved verbatim — `RCElimination` remains the
guard that flag-off builds never leak RC ops into codegen.

### 15.3 Lowering (`Passes/EcoToLLVMRc.cpp`, new)

`IncrefOpLowering`/`DecrefOpLowering`/`FreeOpLowering` follow the
runtime-call pattern: `ptrtoint` the value to i64, call
`eco_rc_incref(u64 word, i64 amount)` / `eco_rc_decref(u64 word)` /
`eco_rc_free(u64 word)` (§16.2's exact signatures).
The helpers are **GC-leaf** (`gc-leaf-function` declarations, never
allocate, no safepoint) so RS4GC inserts no statepoint and the pointer
legally crosses as a plain i64 word. Registered in `RuntimeSymbols.cpp`
beside the field-store helpers. No new roots, no stackmap changes;
header refcount writes are invisible to tracing (mark/sweep reads
`color`/`age`/`tag` only). HEAP_005 (no old→young edges, no write
barrier) is untouched by counting itself; it constrains RC-1 *mutation*
(§17 S6).

## 16. Runtime RC path

### 16.1 `rcManaged` scope

`rcManaged : MonoType -> Bool` (compiler) + the matching runtime tag set:
v1 = **pointer-free flat buffers** (`Tag_ByteBuffer`, the string
leaf/body forms, HEAP_026 pinned large bodies) per DS6. rcManaged
objects are **still traced** — RC is an accelerator, not the collector
of record; leaked counts are reclaimed by major GC (RC_001's safe
direction).

### 16.2 Helpers (`allocator/RefCount.cpp`, new)

```cpp
static constexpr u32 RC_SATURATED = 0x7FFF;   // sticky ceiling (RC_002)

extern "C" void eco_rc_incref(u64 word, i64 amount) {
    HPointer hp = hpFromBits(word);           // NOT HPointer{word}: first-field init trap
    if (word == 0 || hp.ptr_ind) return;      // null / embedded constant (RC_003;
                                              //   REP_CONSTANT_002: never range checks)
    Header *h = reinterpret_cast<Header *>(word);   // HEAP_028: word IS the address
    u32 rc = h->refcount;
    if (rc == RC_SATURATED) return;           // saturated → trace-only object
    u64 next = rc + static_cast<u64>(amount);
    h->refcount = next >= RC_SATURATED ? RC_SATURATED : static_cast<u32>(next);
}

extern "C" void eco_rc_decref(u64 word) {
    HPointer hp = hpFromBits(word);
    if (word == 0 || hp.ptr_ind) return;
    Header *h = reinterpret_cast<Header *>(word);
    u32 rc = h->refcount;
    if (rc == RC_SATURATED || rc == 0) return; // sticky / untracked (count started 0
                                               //   before reify coverage — safe: GC backstop)
    h->refcount = rc - 1;
    if (h->refcount == 0)
        eco_rc_reclaim(h);                     // §16.3
}
```

Allocation sites for `rcManaged` tags initialize `refcount = 1` (the
field is currently zero-initialized and ignored — one line per alloc
helper); the interning table stamps `RC_SATURATED` on interned literals;
builder-bit machinery is untouched (builder objects are pre-escape,
count 1). **Header-preservation obligation**: minor-GC copy and
promotion must carry the header word — including the `refcount` bits —
verbatim to the new location; if any copy path rebuilt headers, every
survivor would reset to 0 = "untracked" and RC-1 would silently die for
promoted objects. Audited and pinned by an ECO_HEAP_VALIDATE check at
B4.

### 16.3 `eco_rc_reclaim` — per-generation semantics

There is no single-object free API (DS6); reclaim dispatches on
residency (`Allocator::isInNursery/isInOldGen`):

- **Nursery:** no-op. The copying nursery reclaims dead objects for free
  at the next minor GC; the zero count was still profitable — it is what
  RC-1 and `DropFree` classification consumed statically.
- **Old gen:** convert to `Tag_Free` (`header.size` = byte count via
  `getObjectSize`) and link into the size-class free list — the
  `freeLargeBodyCell` mechanism (HEAP_027) generalized to mutator time.
  v1 restricts this to pointer-free tags: no child traversal, and
  `eco.decref_shallow` vs `eco.decref` is moot. v2 (arrays) adds the
  child-decref walk sharing `markChildren`'s per-tag layout switch.
- **Pinned large bodies** (HEAP_026): reclaim via the existing
  `OldGenSpace::large_bodies_` bookkeeping.

## 17. Optimistic mutation (RC-1): soundness conditions

RC-1 in-place mutation — at a mutating primitive, check the header
count; 1 ⇒ mutate in place, else copy-on-write — is the headline
consumer. "Optimistic" because it is a per-run dynamic bet with value
semantics preserved either way. Sound iff:

- **S1 — Exact owner counting.** count == number of owning references,
  maintained eagerly at every dup/drop (batched `$amount` is fine
  under §14.2's rule: batch at the first coalesced occurrence, nothing
  intervening — early overcount only). Undercount risk concentrates in
  kernels → §12.3 audit gate.
- **S2 — Owned entry via move.** The mutating primitive takes the object
  `•` by move; only then does count 1 mean sole owner. A borrow-taking
  mutator is unsound by construction.
- **S3 — No live uncounted aliases.** Borrows are count-invisible; the
  statics close the gap: a move at `p` requires `endsBefore ltP p`, and
  every borrow's liveness flows into its owner's lifetime, so sole
  owner + legal move ⇒ zero live borrows anywhere (paper §6.7 + its
  §4.3 ok-invariants). Corollary: borrows materialized as *data* —
  `Tag_StringUtf8View` interior pointers (HEAP_032) — are invisible to
  both the count and the statics; the backing must hold a counted
  reference or be excluded from RC-1 mutation. There is no third option.
- **S4 — Thread exclusivity.** Single-threaded Elm heap (HEAP_007's
  one-heap-per-thread model), else atomic counts + external
  happens-before.
- **S5 — Immortals never pass.** Interned/embedded constants carry
  saturated counts or are `ptr_ind`-skipped, so they can never look
  unique.
- **S6 — GC coexistence (the eco-gating condition).** The generational
  GC is barrier-free by design ("Elm's immutability means no old→young
  pointers exist" — `NurserySpace.cpp:25`); the only sanctioned mutation
  is builder-flagged, nursery-pinned objects (HEAP_BUILDER_001–003).
  RC-1 mutation of a *promoted* object storing a nursery pointer creates
  an edge the collector never sees. v1 resolution (= DS6): RC-1 mutation
  restricted to **pointer-free buffers** (no HPointer slots ⇒ no edges
  possible). v2 options for arrays: builder-style nursery pinning or a
  scoped remembered set — decided in the v2 arrays design.

What borrow inference contributes:

- **H1 — Soundness of the check.** All-owned Perceus RC-1 is trivially
  sound; borrow inference deliberately stops counting most aliases —
  S3's exclusivity theorem is the price of admission.
- **H2 — Honest counts.** Transient dups elided ⇒ count reflects genuine
  sharing (the paper's `map_rec` accumulator stays at 1 — guaranteed
  in-place push).
- **H3 — Static upgrade.** Zero dups reaching a class on any path ⇒
  count 1 is a compile-time fact ⇒ `DropFree`/unchecked mutation.
- **H4 — Propagation through abstraction.** Owned-taking mutator
  builtins + Stage C's rule (2) pull the demand up through user-defined
  wrappers.
- **C1 — Caveat: borrowing can *hurt* RC-1.** A borrow living past a
  mutation point forces dup-not-move → count 2 → copy. The paper
  measured it: unify, 6.4% of RC-1 mutations fell back to copies;
  mutation-aware flow analysis is their named future work. For eco: a v2
  Stage-C cost heuristic (penalize borrow lifetimes crossing owned
  mutator-argument flows) — never a soundness issue (the fallback is a
  copy, not UB). The §13 census sizes it before anything is built.

---

# Part IV — Program

## 18. Milestones

Strangler-style; each lands in the production pipeline behind the
existing suites. B0–B3 are engine-independent; B3.5 is the solver-only
handshake; B4+ are the optimization program, each gated on the census of
the milestone before it.

- **B0 — foundation report** (doc-only): the runtime-strategy call with
  DS6's evidence; a cheap Perceus-style syntactic dup-site count;
  the §12.3 kernel counting-audit checklist; the `rcManaged` v1 set
  fixed; the §22.2 view-counting decision.
- **B1 — foundations**: `Borrow/{Lifetime,Dsu}.elm` + unit/property
  tests (§19.1). No pipeline wiring.
- **B2 — intra-def analysis + census**: `Rty/Constrain/Solve` wired as
  Phase 6, `enabled=True, reify=off`; all call boundaries all-owned (no
  sigs yet). Gates: full E2E green flag-on with a **graph-identity
  check** (analysis only); census lands (§13); self-compile wall delta
  measured; elm-aws-codegen canary.
- **B3 — interprocedural**: `Sig.elm`, SCC fixpoint, kernel allowlist
  v1. Gates: B2 gates + census showing boundary recovery
  (`poisonedParams` down); BORROW_005 TestLogic check; wall budget
  (§21).
- **B3.5 — LSS handshake** (solver-only): `lssMemberOrigins` export,
  `LssFacts.elm`, the lambda-sig namespace, stamp shortcut. Gates: B3
  gates under BOTH engines (subst run must be bit-identical to B3 —
  the inert path); solver run shows the `PoisonCause` census split;
  cross-engine A/B archived as the §22.6 evidence.
- **B4 — reification + runtime RC path** (`reify=rc` + `--rc-mode`):
  `MonoRcDup/Drop` + 13-file sweep; emission; `EcoToLLVMRc.cpp` +
  `RefCount.cpp` + symbols; alloc-site count init; interning
  saturation; **`Borrow/Check.elm` (§19.3)**. Gates: full E2E green
  flag-on; `ECO_RC_STATS` dynamic counters reconcile with census
  predictions; ECO_HEAP_VALIDATE clean, including the
  refcount-preserved-across-copy/promotion check (§16.2); tracing mode
  byte-identical flag-off; checker green over the full corpus.
- **B5 — RC-1 + free**: `eco_rc_reclaim` old-gen path; RC-1 checks in
  the scoped buffer kernels (Bytes ops first); `DropFree` on. Gates:
  E2E + the string/slice suite; benchmark suite (self-compile,
  elm-aws-codegen, micros mirroring the paper's text_stats /
  parser-combinator shapes); memory-footprint watch.
- **B6 — v2 program** (each item its own plan, sized by census data):
  mode specialization on the keyed/AbiCloning substrate (§11.2); arrays
  in `rcManaged` (+ child decref + the S6 mutation story); capture
  borrowing (§22.7); mutation-aware Stage-C heuristic (C1);
  drop-sliding; per-ctor `RCustom` precision. **Ordering constraint:**
  per-field dup selectors (§22.4) are a hard prerequisite of admitting
  any pointer-carrying container tag to `rcManaged` with recursive
  `eco.decref` — `MonoRecordUpdate`'s copied-over fields have no
  variable occurrence to attach a dup to, so a recursive drop of the
  update base would decref children the updated record still references.
  The `updateCopiedHeapFields` census counter (§13) sizes this from B2.

## 19. Testing, validation, and the certifying checker

### 19.1 Unit level (B1)

Property tests on randomized skeletons: `join` assoc/comm/idem; `leq` ⇔
`join`-absorption; `endsBefore`/`onBoundary` against brute-force path
enumeration (the paper's warning that tree orderings are subtle is a
test-generation instruction, not a footnote).

### 19.2 A/B discipline

`enabled=False` byte-identical by construction; `reify=off`
graph-identical (checked, not assumed, at B2); **all-owned mode** (one
flag in `Solve` forcing every access to Owned) reproduces Perceus
behavior and is both the RC-path baseline and the soundness-isolation
tool — any bug that reproduces under all-owned is in
reification/runtime, not in the analysis. Census-vs-`ECO_RC_STATS`
reconciliation (B4) catches placement bugs that both static and dynamic
views would individually miss.

### 19.3 The certifying checker (`Borrow/Check.elm`, B4)

The paper proves the *target* type system sound but explicitly does not
prove inference always produces well-typed output — Morphic runs a
certifying checker on every result. Eco adopts the same backstop,
proportionate to our reified surface: under `borrow.validate`, after
reification, one linear walk per def verifies

- linearity: every owned resource is moved exactly once or dropped on
  every path, never used after its move point (`endsBefore` recheck
  against the recorded `Occ` paths);
- coercion completeness: every owned-demanding position is fed by a
  move, a dup, or an owned-fresh producer — never a bare Borrowed
  source (§9.5);
- BORROW_004: every `MonoRcDrop` names an in-scope binding;
- BORROW_005: no drop after a `MonoTailCall` (hoisted drops sit before
  it);
- no RC op targets an `immortal` or non-`rcManaged`-eligible resource
  when `reify=rc` scoping is on (BORROW_003).

Cheap (one pass over already-computed facts), and it converts "the
solver has a subtle monotonicity bug" from a heap-corruption hunt into a
compile-time diagnostic. Runs in CI for the full corpus at B4.

### 19.4 Known verification traps (inherited from LSS experience)

The corpus is flag-off-shaped and the harness cache is env-blind — touch
all test `.elm` before flag-on gate runs; the harness swallows census
stderr (grep the captured log, `grep -a` — census lines can contain
binary chars); `rc::check` failures don't fail the suite (grep
"Falsifiable"); serial-only E2E vs elm-tests (typed-artifacts cache
race).

## 20. Invariants delta

New rows land with the milestone that makes them meaningful (none are
pre-registered in `invariants.csv` today):

- **BORROW_001** (B2) — resources minted only at §7.2 heap positions;
  scalars/Bool/Unit never carry RC operations.
- **BORROW_002** (B4) — `MonoRcDup`/`MonoRcDrop` produced only by
  GlobalOpt Phase 6, never serialized; pre-Phase-6 observation is a bug
  (`Debug.todo` arms).
- **BORROW_003** (B4) — reified RC ops target only `rcManaged`-typed,
  non-immortal resources; everything else is statistics only.
- **BORROW_004** (B4) — every `MonoRcDrop` target is an in-scope
  let/param binding at its wrap point.
- **BORROW_005** (B3) — no drop after a `MonoTailCall` in the same body.
- **BORROW_006** (B3.5) — `LssFacts` decline ladder: blocked or
  unresolvable members poison; multi-member meets are asymmetric
  (params any-owned-wins, results any-borrowed-wins) per RC_001's safe
  direction; merged sigs are call-site-only artifacts, never cached
  into `sigs`/`lambdaSigs`; `lambdaSigs` reads before the enclosing SCC
  is solved answer `Poison PNoSig`.
- **RC_001** (B4) — for every `rcManaged` object, `Header.refcount` ==
  owning references, maintained eagerly; kernels creating surviving
  references inc before the reference escapes. Overcount/leak = safe
  (GC backstop); undercount = unsound.
- **RC_002** (B4) — `0x7FFF` is sticky saturation; object becomes
  trace-only.
- **RC_003** (B4) — RC helpers no-op on `ptr_ind != 0` and null words
  (REP_CONSTANT_002; never address-range checks, FORBID_HEAP_001).
- **RC_004** (B5) — RC-1 mutation permitted only for pointer-free
  `rcManaged` tags (preserves HEAP_005 without barriers).

Amended: **HEAP_005** gains a note (count writes touch only the header
refcount field, not pointer stores; the no-old→young guarantee is
preserved by RC_004's scope). `RCElimination`'s description becomes
"verifies absence in tracing mode; bypassed in RC mode".

## 21. Performance budgets

- **Compile time**: Phase 6 adds one whole-graph analysis, linear-ish per
  def in AST size × type width; SCC fixpoints multiply only within
  cycles. Budget ≤3% self-compile wall at B3, re-measured per milestone
  (Stage-7a timing is a sensitive, well-instrumented gate after the
  backend rounds).
- **Run time (RC mode)**: helper-call dup/drop first; inline header RMW
  only if counters say it matters — the paper measured 1–3 ns per
  dup/drop pair, so *elision* dwarfs per-op tuning. (House precedent:
  the P2/P2.5/R5 inline-expansion machinery exists if RMW inlining is
  ever warranted.)
- **Code size**: zero-result region-free ops are cheap in both
  serialization paths.
- **Memory**: borrowing extends owner liveness (paper: one benchmark,
  +2.5% peak). The census tracks max borrow extension per def; the B5
  gate includes E2E-corpus footprint.

## 22. Open questions

1. **The B0/M0 runtime-strategy call** — is the v1 payoff (pointer-free
   buffer RC + RC-1 on Bytes/strings + static uniqueness) worth the
   B4/B5 runtime work, or does the program stop at B3.5 (analysis +
   census as an optimization oracle) until arrays justify the runtime
   path? The B2 census is the deciding evidence.
2. **View counting** (S3 corollary): count-at-view-creation (defeats
   some zero-copy wins) vs excluding view-backed forms from RC-1 —
   per-form decision in B0 with the UTF-8 slice machinery in view.
3. **`resultAliases` propagation**: kernels whose result aliases a param
   return a borrow-as-value; v1 models declared aliases as gets
   (vertical flow) and treats undeclared results as owned-fresh. Are any
   kernels *conditionally* aliasing? (Audit question, lands with §12.3.)
4. **`MonoRcDup` selectors** (the paper's per-field `dup s`): v1 dups
   only top-level resources; field-granular selectors become necessary
   only with per-ctor `RCustom` precision (B6).
5. **JS backend**: the JS pipeline shares the Mono graph. v1:
   `reify=rc` is rejected for JS targets (no JS lowering for RC ops);
   analysis/census still runs. Long-term: ignore-arms in the JS emitter.
6. **Engine default**: B3.5's LSS handshake only fires under
   `EngineSolver`. Whether the solver becomes the compiled-in default is
   a standing question owned by the mono program (the JS-hosted-solver
   bootstrap cost is the recorded blocker); the B3.5 cross-engine A/B
   census is this design's contribution of evidence. Until then, stock
   builds get B3-level precision.
7. **Capture borrowing** (v2): borrowing a capture requires proving
   closure-lifetime ≤ capture-lifetime — a genuinely harder judgment
   than call-boundary routing (closures escape). `capturesForcedOwned`
   sizes it; the LSS design's M6 notes and the E8 defunctionalization
   direction both bear on whether it is ever the right lever.

## 23. References

- Paper: `design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`
  (companion LSS paper alongside)
- LSS design (its §9.4 names this pass as consumer M6):
  `design_docs/monomorphization/lambda-set-specialization-design.md`
- LSS census settlements (E8-or-nothing; residual-⊤ evidence):
  `plans/lss-dispatch-value-extraction.md` §12; benchmark record:
  `benchmarks/runtime-calls.md` (Runs A–Q)
- Escape-analysis postmortem: `design_docs/escape-analysis-status.md`
- Solver-reuse evaluation (architecture pattern, kernel honesty):
  `design_docs/monomorphization/solver-reuse-evaluation.md`
- Roc Perceus study: `design_docs/perceus_gc/{README,borrow,inc_dec}.md`
- Mono IR: `compiler/src/Compiler/AST/Monomorphized.elm`
- Pipeline: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm:125-152`,
  `compiler/src/Builder/Generate.elm` (`runGlobalOptPhase`)
- LSS anatomy: `compiler/src/Compiler/MonoSolver/{LssInfer,Engine}.elm`,
  `compiler/src/Compiler/GlobalOpt/AbiCloning.elm`
- Shared infra: `compiler/src/Compiler/Graph.elm`,
  `compiler/src/Compiler/GlobalOpt/Staging/UnionFind.elm`,
  `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`
  (`buildCallGraph`)
- Dialect ops: `runtime/src/codegen/Ops.td:2751-2842`; guard:
  `runtime/src/codegen/Passes/RCElimination.cpp`; pipeline:
  `runtime/src/codegen/EcoPipeline.cpp`
- Heap: `runtime/src/allocator/Heap.hpp` (header layout `:153-165`,
  builder bit `:135-152`), `HeapHelpers.hpp`, `AllocatorCommon.hpp`,
  `NurserySpace.cpp:25`
- Invariants: `design_docs/invariants.csv` (REP_*, CGEN_*, HEAP_*,
  HEAP_BUILDER_*, FORBID_*)
