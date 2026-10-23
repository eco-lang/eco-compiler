# Incremental builds: design exploration

**Status:** exploration only, 2026-10-06. This is not a plan.
- It records the design issues raised in a discussion between the user and Claude, and the
  evidence gathered for them.
- The plan that moves the MLIR whole-program passes into the front end,
  `plans/partitioned-mlir-handoff.md` (link removed: that file no longer exists in the repo), is
  separate and unchanged.
- This exploration names a few things that plan should keep open (`06-granularity-and-scheduling.md` §6).

## The question

Elm already builds incrementally up to type checking. Each module's `.eci`/`.ecot` is reused when
its source and its imports' interfaces are unchanged.

Everything after that runs whole-program on every build, even a no-op one:
- typed-graph load;
- monomorphization and LSS;
- inlining;
- GlobalOpt;
- MLIR codegen;
- the C++ back end.

Monomorphization and inlining break the simple rule "a module depends on what it imports". The
open questions are:
- whether the work after type checking can also be incremental;
- how the program should be sliced into compilation units so that a small source edit dirties as
  few units as possible.

## Documents

| File | Topic |
|---|---|
| `01-current-state.md` | What is incremental today, where the time goes, and what a no-change rebuild costs |
| `02-ownership-and-dependency-direction.md` | The central idea: instances are owned by the module that requests them, which keeps cross-module information flowing in import order. A flow audit of every pass, and the flows that go against it. |
| `03-identity-and-stability.md` | SpecIds, lambda ids and other global counters. Persistent append-only ids, owner-local numbering, content keys. Reproducibility. |
| `04-incremental-monomorphization.md` | "Monomorphization and LSS are demand-driven, so can we re-demand only what changed?" Partly: what blocks it, and what it would need. |
| `05-persistent-state-and-server-mode.md` | Serializing compiler state between runs vs an always-on compiler server |
| `06-granularity-and-scheduling.md` | Unit size chosen for blast radius rather than clean-build throughput; latency model; relation to the partitioned hand-off |
| `07-open-questions-and-experiments.md` | Decisions to make, and the measurements that would inform them |
| `08-dependency-relation.md` | The dependency relation as a union of ~120 named parts: direction, strength, stratum, where each is formed. Measured SCCs, and why the naive union collapses the program into one SCC |
| `09-residual-relation-by-phase.md` | With stable names: what remains of the relation per phase; which edges cross units; how requester ownership, a separate-compilation contract and a thin link (ThinLTO pattern) handle the rest |
| `10-thin-link-design.md` | Thin linking (ThinLTO pattern): the three link points (settles/taint, AbiCloning/sret/psplit, back end), the per-unit summary schemas, solves, slices, cutoff keys and what re-runs |
| `11-reuse-mechanics.md` | Concrete reuse between builds: the artifact ladder (what to cache: `.ecot`, mono, MLIR bytecode, stage-1 MLIR, objects), metadata/traces, when to write and read (verifying traces + early cutoff), object reuse at link and the link unit, the cache store, adoption stages A-D |
| `exp-x11-object-reuse.md` | Measured: with module-aligned units, per-unit objects are deterministic; under stable naming at most 5 of 272 objects (≤ 2.9 % of lowering) change per edit |
| `exp-x1` … `exp-x8` | Results of the eight experiments (2026-10-06); `experiments/` holds patches and scripts |

## Summary of the main ideas

1. **Requester ownership.**
   - **The rule:** a specialization (generic instance, or LSS lambda-set instance) belongs to the
     module that requests it. A nested request inherits its root requester. This is the user's
     "pull the specialization up into the caller's module".
   - **Why it works:** the requester transitively imports every module the instance depends on.
     Elm forbids import cycles, so every cross-module dependency follows import order, and
     facts about a module can be computed bottom-up and cached like `.eci` interfaces.
   - **What it costs:** duplicate instances across requesters (02).
2. **The flows that go against import order are few and identifiable:**
   - whole-graph pooling: staging slot classes; AbiCloning's global instance index; CafDedupe,
     CafHoist, Borrow and MapTemplate member meets;
   - "a call site exists anywhere" gates: sret, psplit, cap-hoist coverage, linkage;
   - LSS demand joins on shared keys (dormant at the default budget);
   - global numbering baked into names.

   An incremental *profile* can bound each with an ordinary separate-compilation rule, at small
   or measurable optimization cost (02 §4). The user accepts losing some optimization in
   incremental builds.
3. **Identity.** Every SpecId, LambdaId, LSS member id and inliner name comes from a whole-run
   counter in discovery order, and is baked into symbol names. Today one edit renames everything
   downstream. Three ways out (03):
   - persistent append-only ids (the user's proposal);
   - owner-local numbering;
   - content keys.

   Under requester ownership with per-requester copies, *cross-module numeric ids mostly
   disappear*: a module only refers to another module's exported, name-identified symbols.
4. **Incremental mono is "partly" possible today** (04). Discovery is demand-driven, and each
   spec gets a fresh solver store. But:
   - LSS joins demands from callers and runs whole-registry post-drain settles;
   - a cross-spec number-taint table depends on order;
   - joins, taints and member tables only ever grow;
   - all ids are whole-run counters.

   Ownership plus owner-scoped tables would turn it into per-module, bottom-up re-specialization.
5. **Persisted state vs a server** (05).
   - Nothing post-mono can be serialized today: there is no Mono codec.
   - A server keeps live heap values with no codec, but on its own it saves only the ~2-8 s of
     cache load/decode.
   - The large wins need incremental mono (23.8 s), codegen (12 s) and back end (~21 s).
   - The runtime needs per-build heap release, a fragmentation answer for a non-moving old
     generation, and IPC and file-watching services that don't exist yet.
6. **Granularity follows blast radius, not clean-build balance** (06).
   - If an edit needs 5 % of the work, its latency is the slowest *dirty* unit's lowering time.
     Units should therefore be small and stable, module-aligned, with large modules split.
   - That raises per-unit overhead on clean builds, which is acceptable in the incremental
     profile.

## Experiment results (2026-10-06)

All eight experiments from `07-open-questions-and-experiments.md` §2 were run.
- **Environment:** a freshly bootstrapped copy of the tree on the 12-core dev container.
- **Write-ups:** `exp-x*.md`.
- **Reproducibility:** patches, scripts and small data files are in `experiments/`. All
  instrumentation is env-gated, and none of it was applied to `/work`'s source.

| # | Experiment | Headline |
|---|---|---|
| X1 | `exp-x1-blast-radius.md` | Today, an edit that adds a spec renumbers 5-9k SpecIds and dirties **83-96 %** of units. With stable names and requester-owned module units, the median edit dirties **1 unit ≈ 0.25 %** of the program (mean 1.9 %). Type changes cascade (~9 %) under any rule. |
| X2 | `exp-x2-duplication-census.md` | 86 % of instances have one requester. Code cost: per-requester copies **+19.5 %**, + package pool **+13.3 %**, dominator sharing **+1.7 %**. Duplication is dominated by `Dict` internals at `String` keys. |
| X3 | `exp-x3-restriction-costs.md` | Runtime tax: module-scoped staging 0 %, exported ⇒ not covered 0 % (but −42-58 % covered, +2 % stackmaps), restricted AbiCloning +2.9 %, package-only inlining **+4.9 %**. All together **+11.9 %**: the costs compound. |
| X4 | `exp-x4-module-size-distribution.md` | Per-unit lowering cost tracks LLVM instructions (r ≈ 0.95), not source lines. Median unit 0.6 s, max 27.5 s. ~100 modules exceed 1 s. Hitting ≤ 1 s per unit needs ≈ 640 units, ≤ 2 s ≈ 425. Under definition ownership, `List`/`Dict` units are 45-48 s. |
| X5 | `exp-x5-per-unit-overhead.md` | 272-327 module units cost the same total CPU as 12 LPT partitions (4-6× fewer declarations, almost no import copies), with **no measurable runtime cost** (±0.3 %) and +1.5-2.2 % `.text`. With requester attribution, lowering wall even beat LPT (46.9 s against 50.4 s). |
| X6 | `exp-x6-warm-timing.md` | A warm no-change build and a one-edit build both cost **~43 s to MLIR** (mono 25 s, codegen 12.3 s, assign 2.9 s, `.ecot` load only 0.6 s), plus ~56 s of back end on 12 cores. Touching `elm.json` makes builds cold. |
| X7 | `exp-x7-owner-scoped-mono-soundness.md` | Owner-scoped mono is **sound only with changes**: ownership by *key* (caller-shaped non-generic specs exist), and post-drain LSS settles must be a narrow whole-program step or degrade to ⊤. A measured two-module counterexample is included. |
| X8 | `exp-x8-server-prototype.md` | A server is viable with a ~0.3 s `majorGC` + release per build (peak 4.8 GB flat, idle 0.6-0.8 GB; 11 GB without). Retained typed state is only ~105 MB / 0.55 s to reload, so a server alone saves nothing. Two slow leaks were found. The compactor is not usable as-is. |

### What changed in the design picture

1. **Order of work confirmed: names, then units, then incremental back end, then incremental
   mono.** Stable naming plus module-aligned units (07 §3 stages 1-2) is cheap: no per-unit
   overhead and no runtime cost. It makes the back end incremental at ~0.25 % of the program per
   typical edit.
2. **Incremental mono is harder than 02/04 assumed** (X7). It needs ownership by key and a
   solution for the settles. It is still the biggest remaining cost (25 s per warm build).
3. **The incremental profile's optimization loss is real but bounded:** about 12 % slower code if
   every restriction is on. R1 (cross-module inlining) and R3 (AbiCloning) are where to spend
   mitigation effort. R2 and R4 are free in time.
4. **A server is a later enabler, not an early win** (X6, X8).
5. **Side finding:** a base-compiler inliner crash (`lookupVar: unbound variable mono_inline_…`).
   The repro is in `experiments/inliner-bug-repro/`; see `exp-x1-blast-radius.md`.
