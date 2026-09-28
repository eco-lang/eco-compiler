# Threaded GC — TLA+ models of the concurrent heap protocols

**Status:** PLANNED (2026-09-28): the master plan for this work, **plus implementation-ready model
plans** (§5). Nothing is implemented. Done so far:
- the dev Dockerfile carries the toolchain (§3); the image has not been built yet;
- the concurrency register exists (§8);
- the primer and the model plans are written, and every PlusCal sketch in them passes the PlusCal
  translator and SANY (tla2tools 1.8.0). **TLC has not been run on any of them.**

**Implementation starts only after the dev container has been rebuilt with the tools** (Step 0),
so the work is repeatable from the image, not from a hand-installed scratch setup.

**Documents:**

| File | What it is |
|---|---|
| this file | goals, the accuracy rules, toolchain, layout, build system, canary, register mechanics, steps |
| `plans/threaded-gc-tla-primer.md` | TLA+/PlusCal for this codebase: C++ → model steps, keeping models small, mutants, trace validation, and a GC glossary. **Read first.** |
| `plans/threaded-gc-tla-M1-snapshot-mark.md` | M1: the 5a–5c snapshot mark cycle over an abstract heap |
| `plans/threaded-gc-tla-M2-slice-control.md` | M2: the marker loop, tickets and termination (the worked example the others follow) |
| `plans/threaded-gc-tla-M3-minor-forwarding.md` | M3: parallel-minor and region-minor forwarding |
| `plans/threaded-gc-tla-M4-promotion-bitmap.md` | M4: old-gen allocation and mark-bitmap bytes, with a data-race detector |
| `plans/threaded-gc-tla-M5-tenuring.md` | M5: 7b/7c concurrent tenuring and 07b ageing, modelled from the merged code |
| `plans/threaded-gc-tla-M6-lifecycle.md` | M6: helper pool, gangs, fork and exit |
| `plans/threaded-gc-tla-M7-pagework.md` | M7: deferred decommit, commit-ahead and the lock order |
| `plans/threaded-gc-tla-W-weak-memory.md` | W1–W5: the real headers under the C11 memory model |
| `plans/threaded-gc-concurrency-register.md` | the rolling record of concurrency bugs (§8) |

**Background:**
- `plans/threaded-gc-master-plan.md` (phases 0–7c done; 7c default-on since TG7d);
- `design_docs/parallel-gc.md`: §2.1 is the snapshot-closure lemma, §3.4 the memory model, §3.5 the
  metadata races;
- the phase plans. The shared-state audit tables are **05c P§3.6** (rows H1–H15), **06 P§3.11**
  and **07 P§3.17** (rows T1–T11). The IM1–IM16 definitions are in 05a:587-595, 05b:574-575/930
  and 05c:628-631; the 7c validators TV1–TV11 are in 07 P§3.19;
- `plans/threaded-gc-07b-tenure-ageing.md` (tenure age k > 1, opt-in).
- `invariants.csv`: HEAP_005/006/007, HEAP_048–070, HEAP_SNAPSHOT_001/002, GC_DET_001,
  FORBID_HEAP_004/005.

---

## 0. Goals and non-goals

**Goals**
1. **Find design bugs before they are silent heap corruption.** Check every concurrent GC protocol
   exhaustively at small scale, including the kernel-write, fork and emergency paths that stress
   runs rarely reach. A lost mark or a double copy is "silent, rare and catastrophic" (master plan
   phase 4).
2. **Cover the collector that copies while the mutator runs.** Phase 7c (concurrent tenuring) is
   built and default-on. It is the first design in which a collector copies objects during the
   mutator's epoch, and the one where a missed case is hardest to see in testing. M5 models it from
   the merged code.
3. **Tie the models to the code, not just to the plans.** Each model states which code it
   describes, is checked against executions of that code (trace validation), and fails loudly when
   that code changes (the canary, §7).
4. **Record every concurrency defect in one place.** Each defect gets a reproduction and a
   regression guard (§8).
5. **Make the models part of the gates.** They run as build targets. Phase plans cite them the way
   they cite validators today.

**Non-goals**
- A proof of the C++ itself. That would need an Iris/VST-class verified semantics, which is out of
  proportion here. §1 states what the plan does claim.
- Modelling policy: pacing, triggers, LAB geometry, size classes. Those are measured, not verified.
  GC_DET_001 stays enforced by IM16 `DecisionScope`.
- One monolithic model of the whole collector. Models are small and composed through stated
  contracts (§5.0).

## 1. What "correct" will mean

No single tool closes the gap between a TLA+ spec and optimised C++20 with relaxed atomics. The
plan closes it in four links. Each link is a separate claim with separate evidence:

| Link | Claim | Evidence |
|---|---|---|
| L1 Design | The protocol, as modelled, satisfies its invariants and its liveness properties | TLC at small scope; Apalache/TLAPS for the few unbounded claims |
| L2 Abstraction | Every atomic step and every shared location in the code has a counterpart in the model | the MAPPING table per model; the footprint tables; the canary (§7) |
| L3 Memory model | The relaxed/acq_rel reasoning the model takes for granted (it assumes sequential consistency) holds under C11/RC11 | weak-memory companions W1–W5 on the real headers (§5.3) |
| L4 Conformance | Real executions of the code are behaviours of the spec | trace validation of the TSan harnesses (§6.3) |

All four links together are strong evidence, but they are not a proof. A model counts as
"complete" when all four are in place for it (§10).

## 2. Accuracy rules (A1–A9): apply to every model

Every model's section in §5 fills in this table. A row left empty is a known hole and must be
written down as one.

| Rule | What it requires |
|---|---|
| **A1 Atomicity** | One model action = one atomic step in the code: a CAS, an RMW, a release store, an acquire load, or one whole critical section. A plain shared load and the write that depends on it are **two** actions. Sequences that look atomic but aren't (e.g. `anyWork()`'s loop of relaxed loads over slots) are split per location. PlusCal labels sit only at these points. Each action cites its code region (A9). |
| **A2 Granularity** | Shared memory is modelled at the unit the hardware shares. Mark bits live in **bytes** that cover 8 slots. Chunk units are 64 cells so that they own whole 64-bit words. A 64-bit header word is atomic, and the plain `memcpy` of a body is not. A model that uses bits where the code uses bytes cannot see lost updates. |
| **A3 Footprint** | The model's variables are the phase plan's shared-state audit rows (H*, T*, 06 P§3.11), plus anything the census (§7) finds. Every row maps to a variable or has a written abstraction argument in MAPPING.md. A shared location with no row is a hole. **Every seed entry in the register is a location that was missing from those tables.** |
| **A4 Weak memory** | The model assumes sequential consistency (SC). Each place where the code relies on a memory order weaker than seq_cst is listed, with the weak-memory companion (W*) that checks it. |
| **A5 Trace validation** | Names the harness and the event vocabulary that the model's trace spec accepts. The event log is the refinement mapping made executable. |
| **A6 Negative controls** | Each invariant has at least one mutant (a `MUTANT` constant or a variant `.cfg`) that TLC **must** reject with that invariant. Where a bug already happened (e.g. 5b's two-load termination), the historical bug is one of the mutants. A mutant that passes means the model is too abstract at that point. |
| **A7 Traceability** | Spec invariants are named after their `invariants.csv` or IM ids, so one id links the CSV row, the spec invariant and the `ECO_HEAP_VALIDATE` check. Model-only properties get `MODEL_<Mn>_<k>` names. |
| **A8 Scope and wrap** | States the small-scope bounds. Counters that wrap in the code are modelled with **tiny widths** so the wrap is reachable (the 31-bit epoch → 2 bits, the 21-bit shadow generation → 2 bits). Unbounded claims name the Apalache/TLAPS obligation that covers them. |
| **A9 Canary coverage** | Lists the code regions (`TLA-REGION` markers), whole files, atomics censuses and footprint greps pinned for this model in `test/tla/manifest.txt` (§7). |

## 3. Toolchain

**Done (2026-09-28):** `docker/eco-dev.Dockerfile` installs:

| Tool | Version | Pinned | Use |
|---|---|---|---|
| Temurin JRE (Adoptium) | 21.0.12.1+1, amd64/arm64 | SHA256 | TLC, SANY, PlusCal, Apalache. Apalache 0.62.x needs Java 21 (class file 65); bookworm's openjdk-17 cannot load it |
| `tla2tools.jar` | **1.8.0** (build 2026.09.25, rev 8f4bc8b) | SHA256 | `tlc`, `sany`, `pcal`, `tlatex` wrappers in `/usr/local/bin` |
| CommunityModules-deps | 202609120237 | SHA256 | Json/IOUtils (trace validation), SequencesExt, Functions |
| Apalache | 0.62.2 | SHA256 | `apalache-mc`: inductive invariants, larger parameters |
| TLAPS `tlapm` | 1.6.0-pre | **no** (rolling pre-release, ~880 MB) | opt-in: `--build-arg INSTALL_TLAPS=1` |
| graphviz | apt | apt | renders TLC `-dump dot` state graphs |

`TLA_TOOLS_DIR=/opt/tlaplus` is exported. The image build model-checks a smoke spec and runs
`apalache-mc version`.

**Settled by testing the real tools** (a scratch JRE, 2026-09-28):
- **1.8.0, not 1.7.4.** The current CommunityModules fail on 1.7.4 with
  `NoClassDefFoundError: tlc2/value/impl/KSubsetValue`, and trace validation needs them.
  - 1.8.0 build 2026.09.25 plus CommunityModules 202609120237 model-checks the smoke spec.
  - 1.8.0 is a **rolling** pre-release (upstream re-uploads the asset in place), so the SHA pin
    will one day fail the image build. When it does, re-hash deliberately, then re-run `tla-check`.
- **The Dockerfile's first smoke spec was wrong** (it lacked `EXTENDS Naturals`) and would have
  failed the build. It is fixed, and the fixed spec was checked under `dash` and TLC.
- **Eleven PlusCal and SANY pitfalls** found while translating the sketches are in the primer §2.
  One matters for the build: SANY exits 0 even when it reports errors (§6.1).

**Still to decide in Step 0:**
- **Non-Docker hosts** (`mac-build`, `win-build`). CMake finds Java with `find_package(Java 17)`
  and the jars through `TLA_TOOLS_DIR` or `-DTLA2TOOLS_JAR=`. It falls back to `eco_fetch` into
  `build/toolchain/` using the same SHA pins. Java itself stays a host prerequisite.
- **The weak-memory tool** (`plans/threaded-gc-tla-W-weak-memory.md`). GenMC is the first choice,
  with C11Tester and herd7 litmus tests as fallbacks. Install nothing until its feasibility spike
  passes.

## 4. Repository layout

```
test/tla/
  README.md               how to run; rules A1–A9; how to add a model
  CMakeLists.txt          tla-check, tla-check-deep, tla-trace (§6)
  models.txt              registry: model, module, config, tier, tool, expected outcome
  run_models.py           runner: exit status + expected-violation matching, mutants
  manifest.txt            canary manifest (§7)
  footprint-greps.txt     footprint row id -> path glob + regex (the phase plans' Step 0 greps)
  common/                 shared modules: Bag-deque, abstract heap graph, race-detector helper
  M<n>-<name>/
    <Name>.tla            PlusCal source + committed translation
    MC_quick.cfg          tier quick (seconds; runs in tla-check)
    MC_deep.cfg           tier deep (minutes to hours; tla-check-deep)
    mutants/*.cfg         one per negative control (A6), each naming its expected violation
    Trace<Name>.tla       trace-validation spec (A5)
    MAPPING.md            action <-> code region <-> footprint row <-> invariant id
    AUDIT.md              dated re-audit log, one entry per canary repair (§7.4)
test/genmc/               weak-memory companions W1–W5 (§5.3)
test/scripts/check-tla-manifest.sh   the canary (§7), like check-kernel-license-manifest.sh
```

## 5. The models

### 5.0 Composition: contracts between models

Each model stays small by **assuming** what another model **guarantees**. Every contract is checked
as a property in the model that provides it and used as an atomic action (or an axiom) in the models
that consume it. This is informal assume-guarantee reasoning; a formal compositional proof would
need TLAPS and is out of scope.

| Contract | Provided (checked) by | Used by |
|---|---|---|
| **Drain**: a run ends with every grey entry scanned exactly once and nothing held privately; a stop leaves every unscanned entry in a deque | M2 | M1, M4 |
| **CopyOnce**: each young object is copied at most once, and every slot ends up pointing at its unique copy | M3 | M4, M5 |
| **LaunchJoin**: launch publishes every pause write to the members, join publishes every member write to the mutator, `running()` is exact on the mutator | M6 | M1, M2, M5 |
| **SnapshotCycle**: the t0 greys, allocate-black and deferred frees give "everything reachable at the handoff is marked or allocated after t0" | M1 | M4, M5 |

### 5.1 The model plans

Each model has its own implementation-ready plan. Every plan has the same parts:
- the protocol in plain words, with worked timelines;
- a code map (file:line, post-7c tree);
- the abstractions and why each is sound;
- constants, variables, and a label-to-code table;
- a PlusCal sketch that passes the translator and SANY;
- the properties, the mutants, and the configurations (quick and deep, with the expected outcome of
  each);
- the A1–A9 table;
- trace validation (events, hook points, harness);
- implementation steps and open questions.

| Model | Plan | Protocol | Code | Contracts |
|---|---|---|---|---|
| M1 | `…-M1-snapshot-mark.md` | the snapshot mark cycle: t0 snapshot, allocate-black, deferred frees, background episodes, assists, closing, emergency join, handoff; the snapshot-closure lemma | `ThreadLocalHeap.cpp` cycle driver, `OldGenSpace.cpp` 4084–4760 | uses Drain, LaunchJoin; provides SnapshotCycle |
| M2 | `…-M2-slice-control.md` | `runMarkerLoop`: tickets, private stacks, deques, termination word, Member/Assist roles, joiners, stop; in five environments | `MarkWork.hpp`, the five `Env`s | provides Drain |
| M3 | `…-M3-minor-forwarding.md` | claim → BUSY → publish on header words, spine runs, YLOS colour test, LAB fillers; phase 6 and 7b | `MinorWork.hpp`, `NurseryParallel.cpp`, `NurseryRegion.cpp` | uses Drain; provides CopyOnce |
| M4 | `…-M4-promotion-bitmap.md` | promotion chunks, the stash, sweep slices inside the promotion lock, allocate-black, grant blocks, **at mark-byte granularity with a data-race detector** | `OldGenSpace.cpp` 487–1600, 5220–5400; `OldGenTenure.cpp` | uses SnapshotCycle, CopyOnce |
| M5 | `…-M5-tenuring.md` | region nursery epochs, the tenure job, shadow forwarding, exact and L3 engines, stop and help, merge and heal, STW-major redirect, t0 young walk, 07b ageing | `TenureWork.hpp`, `NurseryTenure.cpp`, `NurseryRegion.cpp`, `OldGenTenure.cpp` | uses Drain, LaunchJoin, SnapshotCycle |
| M6 | `…-M6-lifecycle.md` | helper jobs, `GCMarkGang`, `GCBackgroundGang`, atfork handlers, exit, fork from a non-mutator thread | `GCHelperPool.cpp` | provides LaunchJoin |
| M7 | `…-M7-pagework.md` | deferred decommit, commit-ahead, and the lock order `promo_mu_` → `thread_mutex_` → pool `m_` | `PageWork.cpp`, `Allocator.cpp` | uses LaunchJoin |

**Expected failures, by design.** Some configurations reproduce register entries and are expected
to fail until the entry is fixed:
- M2 `episode_stop` → CR-005;
- M4's race detector and faithful sweep paths → CR-001, CR-002, and the suspected CR-014 / CR-016;
- M5's `fork` configuration → CR-013 (if it is not dismissed with CR-004);
- M6's non-mutator fork → CR-003, CR-015, possibly CR-004 and CR-005.

`models.txt` records them as "expected: violates X". Such an entry flips to "expected: pass" in the
same change as the fix. This is the register's Reproduced → Guarded step (§8).

### 5.2 Future models (added by the phase that needs them)

Each new concurrent phase adds its model **before** its implementation step. Candidates:
- phase-8 concurrent bitmap clearing / double-buffered bitmaps;
- concurrent evacuation of sparse old-gen pages (this breaks HEAP_006 unless forwarding stays off
  the header);
- the async `bump.end` doorbell (Dekker ordering, parallel-gc.md §3.2);
- multiple mutators, if they ever go beyond the benchmark driver.

### 5.3 Weak-memory companions (not TLA+): W1–W5

These run the **real headers** under a C11 model checker. Each is a 2–3-thread driver. The full
plan, including the concepts and the tool spike, is `plans/threaded-gc-tla-W-weak-memory.md`.

| Id | Pattern | Code | Used by |
|---|---|---|---|
| W1 | Chase–Lev push/take/steal/grow as implemented (element store release, steal acquire) | `MarkWork.hpp:63-195` | M2, M3 |
| W2 | Publish (push or `priv` store) → `goIdle` RMW vs the decider's acquire load + relaxed `anyWork` | `MarkWork.hpp:246-395` | M2 |
| W3 | Mark byte: the marker's test-before-`fetch_or`, allocate-black `fetch_or`, the cursor's plain `setBit` (different byte, IM13), the gap sweep's plain `clearBit` (CR-002) | `OldGenSpace.cpp`/`.hpp` bit helpers | M1, M4 |
| W4 | Block publication: `blocks_.add` → `mark_.assign` → `commitThrough` → page-index release store vs the marker's `blockIdFor` acquire loads; the relaxed grow-only region bounds; `committed_` release/acquire | `OldGenSpace.cpp:586-665`, `ReservedArray.hpp` | M1 |
| W5 | Claim → copy → publish on a header word (phase 6) and on a shadow word (7c), including the exact engine's claim-free publish | `MinorWork.hpp:51-75`, `TenureWork.hpp` | M3, M5 |

## 6. Build system

### 6.1 Targets

| Target | Where defined | Runs | Needs | Budget |
|---|---|---|---|---|
| `tla-canary` | top-level `CMakeLists.txt`, in **ALL** (like `kernel-license-check`) | `test/scripts/check-tla-manifest.sh` | sh, awk, sha256sum | milliseconds |
| `tla-check` | `test/tla/CMakeLists.txt` | SANY parse; PlusCal translation freshness; every `MC_quick.cfg`; every mutant (must fail with its named invariant) | Java 17, tla2tools | ≤ 5 min total |
| `tla-check-deep` | same | `MC_deep.cfg`, Apalache inductive checks, TLAPS proofs if `tlapm` is present | + Apalache, TLAPS | nightly / manual |
| `tla-trace` | same | builds the TSan harnesses with `-DECO_TLA_TRACE=1`, runs them, validates each ndjson trace with TLC | + g++ | ≤ 15 min |
| `genmc-check` | `test/genmc/` | W1–W5 | the chosen tool | ≤ 10 min |

- **SANY's exit status is not a verdict.** SANY exits 0 even when it prints `*** Errors: N`, so the
  runner fails on that text as well as on the status. The same applies to any tool whose status has
  not been confirmed by a deliberately broken input.
- **Translation freshness.** `tla-check` re-translates each PlusCal module into a scratch copy and
  fails if the committed translation differs. This works with either tla2tools version.
- **Mutant expectations.** `models.txt` names each mutant's expected outcome. The runner checks
  TLC's exit status **and** the violated invariant's name. A mutant that passes, or that fails for a
  different reason, fails `tla-check`.
- **Missing tools.** `tla-check` fails with a clear message ("use the dev image or set
  `TLA2TOOLS_JAR`"); it never skips silently. `-DECO_TLA=OFF` leaves the Java targets undefined on
  hosts without Java. The canary needs no Java and always runs.
- **Output convention.** As with every suite (CLAUDE.md), agents run
  `cmake --build build --target tla-check 2>&1 | tee /tmp/test_output.txt` **once** and read the
  file.

### 6.2 Gates

- The canary gates every build (it is in ALL).
- `tla-check` joins the threaded-GC standing gates (master plan §2) for any phase that touches a
  canary region. Proposed amendment to master plan §2: *"A phase that changes a protocol modelled
  under `test/tla/` updates the model, its MAPPING.md and AUDIT.md in the same change, and passes
  `tla-check` and `tla-trace`."*
- `tla-check-deep` and `genmc-check` run at each model's close-out and before each phase flips to
  default-on.

### 6.3 Trace validation mechanics

- **Hooks.** An `ECO_TLA_TRACE(evt, …)` macro in the std-only headers (`MarkWork.hpp`,
  `MinorWork.hpp`, `GCHelperPool.cpp`), with a few calls in `OldGenSpace.cpp`/`NurseryParallel.cpp`.
  It compiles to nothing unless `ECO_TLA_TRACE` is defined, which only harness builds do. Production
  code and counters are unchanged, and `out.mlir` stays byte-identical.
- **Ordering.** Each thread writes events to a private buffer with a sequence number.
  - Events that are RMWs on a shared word log the value they observed and wrote. RMWs on one
    location are totally ordered, and the state word's epoch field is a ready-made clock.
  - The merger builds one interleaving consistent with per-thread order and per-location
    modification order. Where the order is ambiguous, the trace spec admits either order.
  - A global seq_cst sequence counter is **not** used in TSan builds: it adds happens-before edges
    that would hide the races TSan exists to find. Trace builds and TSan builds are separate
    configurations.
- **Spec side.** `Trace<Name>.tla` reads the ndjson with CommunityModules `Json`, and constrains
  `Next` to match each logged event, allowing hidden steps where logging is partial. The trace is
  accepted iff TLC finds a behaviour that matches it. This is the pattern of Cirstea, Kuppe, Merz
  et al. (2024), as used for etcd-raft and CCF.
- **A rejected trace is a finding.** Either the code did something the design forbids (register
  entry), or the model is inaccurate (fix the model and write an AUDIT.md entry). Both outcomes are
  recorded.

## 7. Keeping the models in step with the code: the canary

### 7.1 Why not just hash whole files

Hashing `OldGenSpace.cpp` (7,679 lines) would fire on every unrelated edit and train everyone to
re-bless without looking. So the canary pins four kinds of evidence, each as narrow as possible:

| Kind | Pins | Normalisation | Used for |
|---|---|---|---|
| `file` | a whole file | none | small std-only protocol files where every line matters: `MarkWork.hpp`, `MinorWork.hpp`, `GCHelperPool.{hpp,cpp}`, `PageWork.{hpp,cpp}` |
| `region` | the text between `// TLA-REGION(<id>) begin` and `// TLA-REGION(<id>) end` | `//` comments stripped, whitespace collapsed | functions inside large files (A9 lists per model) |
| `census` | every line in a file matching the **concurrency regex**: `std::atomic`, `atomic_ref`, `memory_order`, `compare_exchange`, `fetch_(add\|sub\|or\|and)`, `.exchange(`, `atomic_thread_fence`, `mutex`, `lock_guard`, `unique_lock`, `condition_variable`, `SpinMutex`, `pthread_atfork`, `std::thread` | whitespace collapsed, line numbers dropped, sorted | the **coverage direction**: a new atomic or lock anywhere in `runtime/src/allocator/` fires even when no region was edited |
| `grep` | the matches of each footprint row's re-derivation grep (`footprint-greps.txt`, taken from the phase plans' Step 0 audits) | as for census | plain shared fields such as `gc_phase_ =`, `region_end_ =`, which the census cannot see |

Census and grep entries store the **matched text itself** (in `test/tla/census/`) as well as its
hash. A failure then prints the added and removed lines, not just "hash changed".

### 7.2 What the checker verifies

1. **Hash:** every manifest line still matches.
2. **Coverage, markers:** every `TLA-REGION` marker in the tree is in the manifest, and every
   manifest region exists in the tree.
3. **Coverage, models:** every model in `models.txt` has at least one manifest line (or is marked
   `plan-only` while its code is still being written), and every manifest line names existing models.
4. **Coverage, footprint:** every row id in `footprint-greps.txt` appears in some model's
   MAPPING.md, either as a variable or as a written abstraction.

This follows `check-kernel-license-manifest.sh` (LSS_022), which checks hashes and coverage for
the same reason: a guard that only checks hashes lets new code arrive unguarded.

### 7.3 The failure message (verbatim intent)

```
TLA+ model canary: code covered by a concurrency model has changed.

  region  OldGenSpace.cpp  lazySweep.phase-change        models: M4
  census  OldGenSpace.cpp  concurrency lines +1 -0       models: M1 M4
      + std::atomic_ref<uint64_t>(meta.live_bytes).fetch_add(n, std::memory_order_relaxed);

DO NOT just repair the hash. The models named above may no longer describe the code.
Before running --update:
  1. Read the change. Does it add, remove or reorder an atomic step, a lock, a shared
     location or a memory order? Does it touch a footprint row (MAPPING.md)?
  2. Check each affected action and variable in the named models' MAPPING.md.
  3. If a model no longer matches: update the spec and MAPPING.md, then run
       cmake --build build --target tla-check      (mutants included)
     and, if the change is in a traced path, tla-trace.
  4. Add an AUDIT.md entry to EACH named model: the date, what changed, the verdict
     (no model change needed / model updated, and why), and the new hash prefix: 3f9a1c2e7b04
  5. Only then: test/scripts/check-tla-manifest.sh . --update
If the change looks like a defect, add it to plans/threaded-gc-concurrency-register.md.
```

### 7.4 The re-audit protocol

- **`--update` refuses** while any named model's AUDIT.md lacks an entry that quotes the new hash
  prefix. The auditor has to write down the verdict before the manifest accepts the new hash. This
  is a stronger form of LSS_022's "`--update` is the last step of a re-audit, never a way to make a
  red build green".
- **An AUDIT.md entry** records the date, the region or census, a one-line description of the code
  change, the verdict, the model changes made (if any), and the `tla-check` result.
- **Escape hatch for work in progress:** `ECO_TLA_CANARY=warn` turns the failure into a warning,
  for a branch in the middle of a phase. Phase gates, CI and merges run strict.
- **Configure-time DEPENDS** are read from the manifest, as LSS_022 does, so touching a pinned file
  re-runs the canary without a reconfigure. A new marker needs a reconfigure, and coverage check 2
  catches the case where that was forgotten.
- **Proposed invariant row** (lands in Step 1), modelled on LSS_022: *GC_MODEL_001: every code
  region, file, census and footprint grep in `test/tla/manifest.txt` matches its pinned hash, and
  each hash change is justified by an AUDIT.md entry in every model that names it.*
- **Proposed CLAUDE.md line** (Step 1), under Invariants: *"Before modifying GC concurrency code,
  read `test/tla/README.md`; a `tla-canary` failure means investigate the named models first."*

## 8. The concurrency register

**File:** `plans/threaded-gc-concurrency-register.md`, created 2026-09-28 with the issues found
while mapping the protocols. It is a separate file so it can grow for as long as the threaded GC
lives, without churning this plan.

**What goes in:** every suspected or confirmed concurrency defect in the GC or its runtime
interface, whoever or whatever found it. That includes:
- code reading;
- a TLC counterexample;
- a rejected trace;
- a TSan report;
- a GenMC/C11 finding;
- a validator abort;
- a determinism mismatch;
- a stress crash.

Also recorded:
- **coverage gaps:** a protocol path no harness exercises;
- **premise drift:** a plan or comment claims something the code does not do, and a model or audit
  relies on the claim.

**Mechanics (also written into the register's header):**
- **Ids:** `CR-NNN`, assigned in order, never reused. Entries are never deleted; closed ones stay as
  history.
- **Lifecycle and the evidence each step requires:**

  | Status | Entered when |
  |---|---|
  | Suspected | someone has a plausible reading or hypothesis (cite file:line and the function name) |
  | Confirmed | code reading establishes the access pattern beyond doubt, **or** a model produces a counterexample from a MAPPING-faithful model |
  | Reproduced | a recorded command makes it happen or makes a checker report it: a TSan harness, GenMC/C11 driver, TLC trace, unit test or stress config |
  | Guarded | a regression guard (test, validator, mutant or harness scenario) **fails on the current code**; it may land disabled or expected-fail until the fix |
  | Fixed | the fix has landed, the guard passes, and the guard fails again when the fix is reverted (the negative-control rule) |
  | Closed | the fix has been through the relevant phase gates |
  | Not-a-bug / Won't-fix / Duplicate | exits that need a written argument (preferably a model result) and, for Won't-fix, a guard that notices if the accepted premise changes |

- **Severity:**

  | Class | Meaning |
  |---|---|
  | S1 | unsound: a live object freed, lost or corrupted |
  | S2 | a C++ data race (undefined behaviour) whose effect is benign today; must still be fixed, because the compiler may exploit it |
  | S3 | liveness: deadlock, livelock, unbounded stall |
  | S4 | environmental robustness: fork, exit, signals, multiple heaps |
  | G | coverage gap |
  | D | premise drift |

- **Entry template:** status, severity, found (date, how), where (file:line **and** function, with
  the tree date, since line numbers drift), models, invariants, repro, guard, fix, then description
  / evidence / why it matters / next step, and a dated history log.
- **Keep the summary table at the top current**, sorted by status and then severity.
- **Update points:**
  - at every discovery;
  - at each model step's close-out;
  - at each threaded-GC phase close-out (master plan §4 row: "register: N open");
  - whenever a canary audit (§7.4) turns up a defect.
- **Cross-links:**
  - each entry names the model that should catch it, and the model's A6 row lists the entry's
    mutant;
  - a fixed entry's guard is named in the relevant phase plan's gates.

## 9. Steps

Each step lands with its own gates. The model plans (§5.1) are the detailed work plans for Steps
2–7; each ends with its own implementation checklist.

| Step | Content | Exit |
|---|---|---|
| **0** Container and decisions | **Rebuild and restart the dev container** from `docker/eco-dev.Dockerfile` and confirm the image's smoke tests. Nothing below runs on a hand-installed toolchain. Spike the weak-memory tool (W plan §2). Re-derive the H*/T* tables and the census against the current tree. Triage the register's Suspected entries (§8). | tools in the image; tool choices recorded in §3; census baseline; register triaged |
| **1** Scaffolding and canary | `test/tla/` layout, the runner, `models.txt`, the `tla-check` and `tla-canary` targets, `check-tla-manifest.sh` with `--update` and the AUDIT gate, the census and footprint greps, the GC_MODEL_001 row, the CLAUDE.md line, the README. A toy model (the primer's `LostBit`) proves the targets end to end, including a mutant. | canary green in ALL; `tla-check` runs the toy model and its mutant |
| **2** M2 + W1/W2 + trace pilot | the M2 plan's §9 checklist | all four links (§1) for M2; CR-005 Reproduced; `tla-trace` in place |
| **3** M1 + the lemma + W3/W4 | the M1 plan's checklist | MODEL_M1_1 / IM2 checked; the `P1 = FALSE` counterexample recorded; the lemma discharged |
| **4** M4 races | the M4 plan's checklist; the CR-001 heap-tsan scenario | CR-001/002 Reproduced, then Guarded |
| **5** M5 tenuring + W5 | the M5 plan's checklist | all four links for M5 |
| **6** M3 forwarding | the M3 plan's checklist | all four links for M3 |
| **7** M6 + M7 | both plans' checklists; the fork harness (CR-008) | CR-003/004/005/007 reproduced or dismissed |
| **8** Deep tier, nightly | `tla-check-deep` and `genmc-check` in the nightly routine; the master plan §2 amendment lands | models gate phase flips |

**Why this order:**
- M2 is first: it is the smallest, it is shared by five environments, and it has a real historical
  bug to validate against.
- M1 depends on M2's Drain contract.
- M4 comes early because two register entries live in it.
- M5 comes after the M1/M2 contracts it uses exist.

## 10. Done means

- For each of M1–M7, all four links (§1) are in place: TLC quick and deep pass, the mutants fail as
  expected, MAPPING.md covers every footprint row, the W companions pass (or the A4 row says why
  none is needed), trace validation runs in `tla-trace`, and the canary pins its regions.
- The canary is in ALL, GC_MODEL_001 is in `invariants.csv`, and the master plan §2 standing rule
  is amended.
- Every register entry that existed at Step 0 is at Guarded or beyond, or has a written exit.

## 11. Tracking

| Step | Status | Outcome / facts for later steps |
|---|---|---|
| Plans | **DONE (2026-09-28)** | primer, M1–M7, W; sketches pass `pcal` + SANY; TLC not run |
| 0 Container and decisions | Dockerfile done (tla2tools 1.8.0 pin, fixed smoke spec); image not built | 1.8.0 vs 1.7.4 settled (§3) |
| 1 Scaffolding + canary | not started | |
| 2 M2 | not started | exploration of an earlier draft: `minor` = 111,952 distinct states; a 5-node episode > 22 M unfinished; the epoch needs a state constraint (M2 plan §4.7, §6.1) |
| 3 M1 | not started | |
| 4 M4 | not started | |
| 5 M5 | not started | 7c merged and default-on (TG7d) |
| 6 M3 | not started | |
| 7 M6 + M7 | not started | |
| 8 Deep tier | not started | |

## 12. Traps

1. **Modelling the plan instead of the code.** The mapping agents found several places where the
   code differs from its plan:
   - `running_` is set inside the lock;
   - the Chase–Lev orders are stronger than the paper's;
   - `region_end_` is written without the setter;
   - the plan says pool workers are "detached", but they are joinable.

   MAPPING.md cites code, never plan text.
2. **Treating `anyWork()` or `publishAll()` as atomic.** They are loops over separate locations.
   Merging them into one action erases exactly the interleavings that broke 5b.
3. **State explosion from modelling the heap in M2–M4.** Use the contracts (§5.0). A model that
   needs more than a few minutes at quick scope is too big: split it.
4. **A mutant that "fails" for the wrong reason** (deadlock, a type error, a different invariant)
   proves nothing. The runner matches the invariant's name.
5. **Trace hooks that change the schedule.** Keep trace builds separate from TSan builds (§6.3), and
   never put a hook on a production path unless it is compiled out.
6. **Re-blessing the canary in bulk** after a large refactor. Every named model still gets its own
   AUDIT.md entry. A "no model change" verdict is fine; a missing verdict is not.
7. **Believing TLC at small scope proves the unbounded claim.** A8 names the unbounded obligations.
   Wrapping counters are shrunk until the wrap is reachable.
8. **Unbounded counters make the state space infinite.** M2's epoch grows without bound because
   idle markers can re-wake forever. The runner must then time out, not report success. Every
   model states its state constraints, and a configuration that hits the TLC time limit counts as
   a failure.
9. **Checking a model on a hand-installed toolchain.** The pins in the image are the reference.
   Results from any other tool version are not comparable, which is why Step 0 rebuilds the
   container first.
