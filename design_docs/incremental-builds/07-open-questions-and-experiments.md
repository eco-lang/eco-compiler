# 07: Open questions, decisions and experiments

## 1. Decisions to make (none made yet)

| # | Decision | Options | Notes |
|---|---|---|---|
| Q1 | Where instances live | A per-requester copies / B dominator sharing / C package pool / hybrid A + C | 02 §2.1. Decide with experiment X2. |
| Q2 | Identity scheme | Persistent append-only ids / owner-local numbering / content-derived names / hybrid | 03 §3 suggests owner-local + `(module, name)` + append-only pool ids |
| Q3 | Reproducibility policy | Keep G6 byte identity / relax to "up to renaming" / dev builds non-reproducible | The user's view: undesirable but not a deal breaker. Q2's hybrid keeps G6 outside the pool. |
| Q4 | Cross-module inlining in the incremental profile | Package-only / exposed unfoldings with fingerprints / none | The user accepts reduced inlining |
| Q5 | Incremental vs release profile | One configuration, or two (release stays whole-program) | Two means two configurations to test |
| Q6 | Persisted middle ground vs server | Disk-only / server + small persisted core | 05 §4: the server pays off after incremental mono |
| Q7 | Unit granularity rule | Module-aligned with large-module splitting and stable bucket merging | 06 §3. Decide with X4 and X5. |
| Q8 | Order of work | See §3 | — |

## 2. Experiments, all cheap relative to building the feature

> **All eight were run on 2026-10-06.** Results are in `exp-x1-blast-radius.md` …
> `exp-x8-server-prototype.md`, and the README has a summary table.
>
> How they bear on the §1 decisions:
> - **Q1:** A+C (+13 %) or B(+C) (+1.7 %, needs stable cross-module ids). Definition placement
>   is worst. (X1, X2)
> - **Q2:** stable naming is the first-order win. (X1)
> - **Q4:** package-only inlining costs +4.9 %; prefer small exposed unfoldings. (X3)
> - **Q6:** a server only after incremental mono. (X6, X8)
> - **Q7:** module-aligned units have no overhead; split ~100 hot modules by instruction
>   count. (X4, X5)
> - **New open question (X7):** how to handle LSS settles in per-module mono — a narrow
>   whole-program settle step vs ⊤ degradation.

- **X1. Blast-radius study.** Pure Elm; no back end needed.
  1. Key every spec by its structural key (or a temporary stable rendering of it).
  2. Hash each spec's final post-GlobalOpt body together with the interface facts it consumes.
  3. Apply a corpus of small edits to the self-compile sources:
     - change a literal;
     - add a branch;
     - add a call at a new type;
     - change a record type;
     - rename a local;
     - add a top-level function.
  4. Count dirty specs, dirty modules and dirty units under four rules:
     - (i) today's SpecId ranges;
     - (ii) module-aligned with today's GlobalOpt;
     - (iii) plus the 02 §4 restrictions;
     - (iv) plus package-only cross-module inlining.

  This measures how much each layer buys.
- **X2. Duplication census.**
  - For every spec, list the set of modules whose demand reaches it.
  - Estimate code size and lowering cost under variants A, B and C, and the A + C hybrid.
- **X3. Cost of the restrictions.** Run the self-compile and the benchmarks with each 02 §4
  restriction on:
  - module-scoped staging;
  - module-restricted AbiCloning;
  - exported ⇒ not covered (with and without covered-entry thunks);
  - package-only inlining.

  Measure runtime tax, binary size, stackmaps and gc-leaf count.
- **X4. Module-size distribution.** Measure per-module (owned) lowering cost through
  `eco-boot-native`, and find the modules that need splitting to reach a latency target (e.g.
  ≤ 1 s per unit).
- **X5. Per-unit overhead at module granularity.** Repeat 06 C4 with module-aligned units:
  declaration counts, Σ translate, clean-build penalty.
- **X6. Warm timing gaps.** The 01 §4 list: separate typed-graph-load and assign timers, a warm
  `--stats` run, a warm ELF (9b) run, a timed `.ecot` decode, and GlobalOpt broken out.
- **X7. Soundness of owner-scoped mono.** A proof sketch, then a differential test: ctor-row and
  var-lambda settles per owner, owner-scoped `superTable`, LSS widening per owner (04 §5).
- **X8. Server prototype.**
  - RSS and fragmentation after N rebuilds in one process, with `majorGC` release per build.
  - Whether the test-only compactor can be wired in.

## 3. A possible order of work (sketch, not a plan)

Each stage pays for itself and makes the next one easier.

1. **Stable names.**
   - Owner-local lambda, local-tail and inliner numbering.
   - Order-independent `_tail_`.
   - A fixed kernel-artifact owner.
   - Then SpecIds: owner-local under requester ownership, or append-only.

   Measure with X1.
2. **Module-aligned stable units with content-hashed objects** (06 §5). The back end becomes
   incremental with no dependency tracking. It saves most of the ~21 s back end per edit.
3. **Incremental codegen.** Emit MLIR only for units whose inputs changed. This needs per-unit
   back-end interfaces and fingerprints (02 §6). It saves most of the 12 s.
4. **Requester-owned, per-module incremental mono and GlobalOpt,** with the 02 §4 restrictions in
   an incremental profile (04). This saves most of the ~30 s of whole-program front end, the
   largest and hardest piece.
5. **Server mode** (05), once stage 4 exists: no decode, live dependency state.

The partitioned hand-off plan proceeds independently. 06 §6 lists what it should keep open so it
doesn't block stages 1-3.
