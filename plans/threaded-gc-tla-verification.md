# Threaded GC — TLA+ models of the concurrent heap protocols

**Status:** IMPLEMENTED (2026-09-29). Every model plan (M1–M7), the weak-memory plan (W1–W5 plus
`w_pool_done` and `w_running_chain`), trace validation, the canary and the local gates are built (none of the model checks runs in
GitHub CI: owner's decision, 2026-09-29);
§11 has the per-step detail and §10's "done means" is met except where noted there. Gate results at
close-out (2026-09-29):
- `tla-canary` (in ALL): green, 224 pins (GC_MODEL_001);
- `tla-check`: 219/219 as expected (565 s); `tla-check-deep` TLC rows: 48/48 (6,530 s at one row at a
  time); M1's snapshot-closure lemma proved inductive at 5 objects (Apalache); at 6 objects the base case,
  IM2 and 4 of 15 steps pass (stopped, 3–4 h per step), 8 objects not feasible on this machine;
- `tla-trace`: 135/135 as expected (283 s);
- `genmc-check`: 60/60 as expected (22 s);
- the register grew to 33 entries; every entry that existed at Step 0 is Guarded, Fixed, or has a
  written exit (CR-012 awaits the owner's decision on multiple mutators; CR-004 is a proposed
  Not-a-bug).

History: the plans and their adversarial review were written on 2026-09-28 (§13); implementation
started in the rebuilt dev container the same day.

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
| **A8 Scope and wrap** | States the small-scope bounds. Counters that wrap in the code are modelled with **tiny widths** so the wrap is reachable (the 31-bit epoch → `EpochMod` in M2's `wrap` configuration; the 21-bit shadow generation → a 1-bit field, `GenMod = 2`, in M5's `wrap`, where with three extents the first wrap needs 6 minors). A counter used only for equality is replaced by an exact "changed since I read it" flag rather than bounded by a state constraint (primer §4). Unbounded claims name the Apalache/TLAPS obligation that covers them. |
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
| GenMC | **v0.19.0** (commit `9f6c4c0`), RC11 | git commit; LLVM 19.1.7 from Debian bookworm (`1:19.1.7-3~deb12u1`); a temporary GCC 14.4.0 (SHA256, gpg-checked) builds it and ships its `libstdc++` in `/opt/genmc/lib` | W1–W5, `genmc-check` (`test/genmc/`) | `docker/install-genmc.sh`; builder image `docker/genmc.Dockerfile` (`eco-genmc:0.19.0-llvm19`), copied to `/opt/genmc` by the **opt-in** layer `docker/eco-dev-genmc.Dockerfile` (eco-dev + GenMC; eco-dev itself and CI do not include it); the project's LLVM 21 is untouched |

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
- ~~**The weak-memory tool**~~ **Decided 2026-09-28: GenMC** (W plan §4.2 step 4). The real headers
  compile unchanged: the runner compiles each driver to LLVM IR with clang-19 and the system
  headers (GenMC's own C `pthread.h`/`stdio.h` break libstdc++'s C++20 `<atomic>`), then runs
  `genmc -rc11`. `genmc-check`: 49/49 rows as expected in 22 s. GenMC cannot run `pause`,
  `sched_yield` or `nanosleep`, so the real spin loops are straight-lined in the drivers.

## 4. Repository layout

```
test/tla/
  README.md               how to run; rules A1–A9; how to add a model
  CMakeLists.txt          tla-check, tla-check-deep, tla-trace (§6)
  models.txt              registry: model, module, config, tier, tool, expected outcome
  run_models.py           runner: exit status + expected-violation matching, mutants
  manifest.txt            canary manifest (§7)
  footprint-greps.txt     footprint row id -> path glob + regex (the phase plans' Step 0 greps)
  census/                 the text each census and grep pin hashes (a failure prints the +/- lines)
  common/                 shared modules: TraceLog / TraceInOrder / TraceAnyOrder (trace specs)
  trace/                  TlaTrace.cpp (the recorder linked into trace builds), merge_trace.py
  traces.txt              trace registry: harness targets, trace rows (accept / reject, mutate=)
  run_traces.py           trace runner (tla-trace): build, run, merge, validate with TLC
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
| **Drain**: a run ends with every grey entry scanned exactly once and nothing held privately; a stop leaves every unscanned entry in a deque | M2: `ScanOnce ∧ TerminationSafe ∧ Drain` | M1, M3, M5, M6 |
| **CopyOnce**: each young object is copied at most once, and every slot ends up pointing at its unique copy | M3: `CopyOnceContract` (= `CopyOnce` ∧ at the join `SlotsAtCopy`) | M5 (M4 does not need it: it checks any sequence of promotion requests) |
| **LaunchJoin**: join (and `stopAndJoin`, and `GCMarkGang::run`) returns only after every member returned; `running()` is false only after a join; a stop is honoured at the member's next item boundary | M6: `LJ_JoinExact`, `LJ_RunningExact`, `LJ_RunJoined`. "Launch/join **publishes** the other side's writes" is not SC-checkable: it is a W/TSan obligation (M6 A4). "Stop at the next item boundary" is an obligation on the job body, checked by M2 (marker loop) and M5 (tenure engines) | M1, M2, M3, M5 |
| **PoolJob**: a posted job runs exactly once, in any order; `wait` returns only when the job is Done; Done publishes the runner's writes to the waiter (any waiting thread, not only the mutator) | M6: `PoolRunOnce`, `WaitSeesDone`, `ParentJobsFinish`; "publishes" is W's proposed `w_pool_done` (the fast path reads Done outside `m_`) | M7 |
| **SnapshotCycle**: the t0 greys, allocate-black and deferred frees give "everything reachable at the handoff is marked or allocated after t0"; markers touch only t0-old cells | M1: `IM2` at `H_Free`, `NoReleaseInCycle`, `MarkerFootprint`. In region mode `MarkerFootprint` fails until CR-017 is fixed (`quick_region`) | M5; M4 uses only `MarkerFootprint` |
| **TenureDisjoint**: the merge heals only slots of young objects (or young YLOS); during a cycle the markers' closure holds no young cell, no grant cell and no black copy; every copy made mid-cycle is black; the t0 young walk greys only allocated old cells | M5: `HealYoungOnly`, `MarkerDisjoint`, `YoungWalkValid` (the last fails until CR-017 is fixed: `cycle_major`) | M1 |
| **BitFaithful**: a bit set by allocate-black or a marker is never lost, and cursor, chunk and grant bit sets never touch a t0 byte or another owner's word | M4: `NoLostRequiredBit`, `NoRaceBitmap`, `IM13`, `TV5`, `AllocMapExact` | M1, M5 (both model one mark bit per object) |
| **ReleaseContract**: no released block is still referred to by a cursor, chunk, stash, grant or free-list cell | M4: `ReleasedSafe` (CR-014 and CR-016 are its expected violations) | M7 |

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
| M1 | `…-M1-snapshot-mark.md` | the snapshot mark cycle: t0 snapshot, allocate-black, deferred frees, background episodes, assists, closing, emergency join, handoff; the snapshot-closure lemma | `ThreadLocalHeap.cpp` cycle driver, `OldGenSpace.cpp` 4084–4760 | uses Drain, LaunchJoin, TenureDisjoint, BitFaithful; provides SnapshotCycle |
| M2 | `…-M2-slice-control.md` | `runMarkerLoop`: tickets, private stacks, deques, termination word, Member/Assist roles, joiners, stop; in five environments | `MarkWork.hpp`, the five `Env`s | uses LaunchJoin; provides Drain |
| M3 | `…-M3-minor-forwarding.md` | claim → BUSY → publish on header words, spine runs, YLOS colour test; LAB fillers argued owner-only until the join (not modelled); phase 6 and 7b | `MinorWork.hpp`, `NurseryParallel.cpp`, `NurseryRegion.cpp` | uses Drain, LaunchJoin; provides CopyOnce |
| M4 | `…-M4-promotion-bitmap.md` | promotion chunks, the stash, sweep slices inside the promotion lock, allocate-black, grant blocks, **at mark-byte granularity with a data-race detector** | `OldGenSpace.cpp` 487–1646, 2665–2716, 5220–5480, 5488–5810, 6369–6395; `BitmapScan.hpp`; `OldGenTenure.cpp` | uses M1's `MarkerFootprint`; provides BitFaithful, ReleaseContract |
| M5 | `…-M5-tenuring.md` | region nursery epochs, the tenure job, shadow forwarding, exact and L3 engines, stop and help, merge and heal, STW-major redirect, t0 young walk, 07b ageing | `TenureWork.hpp`, `NurseryTenure.cpp`, `NurseryRegion.cpp`, `OldGenTenure.cpp` | uses Drain, LaunchJoin, SnapshotCycle, CopyOnce, BitFaithful; provides TenureDisjoint |
| M6 | `…-M6-lifecycle.md` | helper jobs, `GCMarkGang`, `GCBackgroundGang`, atfork handlers, exit, fork from a non-mutator thread | `GCHelperPool.cpp` | uses Drain; provides LaunchJoin, PoolJob |
| M7 | `…-M7-pagework.md` | deferred decommit, commit-ahead, and the lock order `promo_mu_` → `thread_mutex_` → pool `m_` | `PageWork.cpp`, `Allocator.cpp` | uses PoolJob, ReleaseContract |

**Expected failures, by design.** Some configurations reproduce register entries and are expected
to fail until the entry is fixed:
- M1 `quick_region` (`MarkerFootprint`) and M5 `cycle_major` / `deep` (`YoungWalkValid`) → CR-017;
- M2 `episode_stop` (`ClosingFinished`) → CR-005;
- M4 `sweep_race_bitmap` → CR-002; `sweep_race_phase`, `sweep_release` → CR-001; `sweep_tail`,
  `sweep_tail_release`, `sweep_tail_live` → CR-014; `sweep_large` → CR-016;
- M5's `fork` configuration → CR-013 (its "possible exit" fails at teardown, see the register);
- M6's non-mutator fork → CR-003, CR-015, possibly CR-004 and CR-005;
- M7 `lock_order_stall` is a **witness** (expected to violate `MODEL_M7_StallWitness`, showing CR-007's
  stall is reachable), not a defect reproduction.

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
| W1 | Chase–Lev push/take/steal/grow as implemented (element store release, steal acquire) | `MarkWork.hpp:63-195` | M2, M3, M5 |
| W2 | Publish (push or `priv` store) → `goIdle` RMW vs the decider's acquire load + relaxed `anyWork` | `MarkWork.hpp:246-395` | M2 |
| W3 | Mark byte: the marker's test-before-`fetch_or`, allocate-black `fetch_or`, the cursor's plain `setBit` (different byte, IM13), the gap sweep's plain `clearBit` (CR-002) | `OldGenSpace.cpp`/`.hpp` bit helpers | M1, M4 |
| W4 | Block publication, in the code's order: the region grows and the page index commits first (`resizePageIndexForRegion`), then `materializeBlock`; the page-index owner release store is the only edge publishing `BlockInfo` to the marker's `blockIdFor` acquire loads; the relaxed grow-only region bounds; `committed_` orders the commit syscall and has no C11 negative control | `OldGenSpace.cpp:586-665`, `ReservedArray.hpp` | M1, M4 |
| W5 | Claim → copy → publish on a header word (phase 6) and on a shadow word (7c), including the exact engine's claim-free publish | `MinorWork.hpp:51-75`, `TenureWork.hpp` | M3, M5 |
| proposed | `w_pool_done`: a pool job's `Done` (release, inside `m_`) read by `wait()`'s fast path or `isDone()` (acquire, outside `m_`); `w_running_chain`: member → `m_` → a foreign joiner's `running_` release → the owner's acquire in `tenureJoin`'s orphan test | `GCHelperPool.cpp:219, 238, 625`; `GCHelperPool.hpp:57, 258`; `NurseryTenure.cpp:613-615` | M6, M7, M5 |

## 6. Build system

### 6.1 Targets

| Target | Where defined | Runs | Needs | Budget |
|---|---|---|---|---|
| `tla-canary` | top-level `CMakeLists.txt`, in **ALL** (like `kernel-license-check`) | `test/scripts/check-tla-manifest.sh` | sh, awk, sha256sum | milliseconds |
| `tla-check` | `test/tla/CMakeLists.txt` | SANY parse; PlusCal translation freshness; every quick configuration; every mutant and every expected failure (must fail with its named invariant) | Java 17, tla2tools | ≤ 5 min **per model**, configurations run in parallel (revised in the 2026-09-28 review: the model plans now have dozens of quick configurations and mutants between them, so a 5-minute total was never achievable; measure in Step 1 and move slow ones to deep) |
| `tla-check-deep` | same | `MC_deep.cfg`, Apalache inductive checks, TLAPS proofs if `tlapm` is present | + Apalache, TLAPS | manual (in the dev container), at model close-out and before a phase flip |
| `tla-trace` | same | builds separate **trace targets** of the harness projects (`-DECO_TLA_TRACE=1`, linked with `test/tla/trace/TlaTrace.cpp`, no TSan), runs them, merges each log, validates it with TLC (`test/tla/traces.txt`, `run_traces.py`) | + g++ | ≤ 15 min |
| `genmc-check` | `test/genmc/` | W1–W5 | the chosen tool | ≤ 10 min |

- **SANY's exit status is not a verdict.** SANY exits 0 even when it prints `*** Errors: N`, so the
  runner fails on that text as well as on the status. The same applies to any tool whose status has
  not been confirmed by a deliberately broken input.
- **Translation freshness.** `tla-check` re-translates each PlusCal module into a scratch copy and
  fails if the committed translation differs. This works with either tla2tools version.
- **Mutant expectations.** `models.txt` names each mutant's expected outcome. The runner checks
  TLC's exit status **and** the violated invariant's name. A mutant that passes, or that fails for a
  different reason, fails `tla-check`. An expected outcome is one of: an invariant name, a
  temporal property name, or `deadlock` (TLC's "Deadlock reached", only in a configuration that
  enables the deadlock check). The review of the model plans (2026-09-28) added three rules:
  - every checked property is a **named invariant**, never a PlusCal `assert` (a failed `assert`
    has no name to match, and it fires in every configuration, pre-empting other targets);
  - a mutant's configuration lists **only its target**;
  - every mutant's plan row carries a hand-traced shortest violating behaviour that fits the
    configuration's bounds, and the implementer confirms it with TLC. A mutant that cannot fail
    proves nothing (the review found such mutants in five plans).
- **Witness configurations.** Some configurations are expected to fail on purpose to show that a
  state is reachable at all (M7's `MODEL_M7_StallWitness`, CR-007's stall). `models.txt` marks
  them `witness`, and the runner treats them like mutants.
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
  default-on, locally in the dev container. **None of the model checks runs in GitHub CI** (decided
  2026-09-29: far too heavy); only the canary, which is a hash check in ALL, runs in every build
  there too.

### 6.3 Trace validation mechanics

- **Hooks.** `ECO_TLA_TRACE("ev", "key", value, …)` from `runtime/src/allocator/TlaTrace.hpp`
  (std-only, declarations only), called in the protocol files (`MarkWork.hpp`, `MinorWork.hpp`,
  `GCHelperPool.cpp`, `PageWork.cpp`) and at a few points in `OldGenSpace.cpp`,
  `ThreadLocalHeap.cpp`, `NurseryParallel.cpp`. It is `((void)0)` unless compiled with
  `-DECO_TLA_TRACE=1`, which only trace targets do; arguments are evaluated only when an event is
  recorded. Production code and counters are unchanged, and `out.mlir` stays byte-identical
  (checked by preprocessing each touched file with the production flags: no trace token, one
  `((void)0)` per hook). The recorder (`test/tla/trace/TlaTrace.cpp`) keeps a buffer per thread
  and writes ndjson at the harness's `end()`.
- **Ordering.** Each thread writes events to a private buffer with a sequence number.
  - Events that are RMWs on a shared word log the value they observed and wrote. RMWs on one
    location are totally ordered, and the state word's epoch field is a ready-made clock.
  - The merger builds one interleaving consistent with per-thread order and per-location
    modification order. Where the order is ambiguous, the trace spec admits either order.
  - A global seq_cst sequence counter is **not** used in TSan builds: it adds happens-before edges
    that would hide the races TSan exists to find. Trace builds and TSan builds are separate
    configurations.
  - Implemented by `test/tla/trace/merge_trace.py`: per-thread order; `put`/`get` keys (every
    getter follows every putter); `rmw` value chains per location (initial value inferred or from
    `locinit`, with backtracking on repeated values); `rd`/`val` reads-from; `clk`/`tick` total
    orders. Each merged event carries a vector clock, so a spec may match in log order
    (`TraceInOrder`) or in any order the clocks allow (`TraceAnyOrder`).
- **Spec side.** `Trace<Name>.tla` reads the ndjson with CommunityModules `Json`, and constrains
  `Next` to match each logged event, allowing hidden steps where logging is partial. The trace is
  accepted iff TLC finds a behaviour that matches it. This is the pattern of Cirstea, Kuppe, Merz
  et al. (2024), as used for etcd-raft and CCF.
  - **Acceptance criterion:** the `.cfg` checks one invariant, "some event is still unmatched"
    (`TLUnmatched` / `TPUnmatched`). TLC reporting it violated means a behaviour matched the whole
    log: the trace is accepted. TLC finishing with no error means rejected; the runner prints the
    furthest event matched.
  - **Negative controls:** a `mutate=drop|set|swap:…` row doctors the raw log and must be
    rejected, so a trace spec that accepts everything fails `tla-trace`.
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
| **8** Deep tier as a gate | `tla-check-deep` and `genmc-check` run locally at each model's close-out and before a phase flips to default-on (not in GitHub CI: too heavy, owner's decision 2026-09-29); the master plan §2 amendment lands | models gate phase flips |

**Why this order:**
- M2 is first: it is the smallest, it is shared by five environments, and it has a real historical
  bug to validate against.
- M1 uses M2's Drain contract, but it does not need M2's model to exist: it assumes the contract,
  which M2 discharges whenever it lands. Building M1 right after Step 1 is equally valid, and M1 is
  the model whose premise (the snapshot-closure lemma) everything else rests on.
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
| Plans | **DONE (2026-09-28)**; adversarial review **DONE (2026-09-28)** | primer, M1–M7, W; each plan corrected against the current tree (§13); corrected sketches pass `pcal` + SANY, W drivers compile; TLC, Apalache and C11 checkers not run |
| 0 Container and decisions | **DONE (2026-09-29)** | image built and in use (2026-09-28: pinned jar hashes, TLC 2026.09.25 rev 8f4bc8b, Apalache 0.62.2 verified). Weak-memory spike done: GenMC 0.19 / LLVM 19, installed by `docker/install-genmc.sh` (the local `/opt/genmc` is a clean build by that script), packaged as the opt-in layer `docker/eco-dev-genmc.Dockerfile` on top of eco-dev, so the standard image and CI do not depend on it. Census baseline: the canary's `test/tla/census/` (25 files) and footprint greps, first pinned 2026-09-29. Register triaged: every Suspected entry settled by a model, a harness or a written analysis (only CR-033, found late, is still Suspected). No TLAPS, C11Tester or herd7 |
| 1 Scaffolding + canary | **DONE (2026-09-29)** | the `test/tla/` layout, `run_models.py` (SANY error text, translation freshness, TLC and Apalache rows, `violates:`/`witness:`/`deadlock` outcomes, `--tool`, `--java-opts`), `models.txt`, `tla-check` / `tla-check-deep` (`ECO_TLA`), the README, the toy `LostBit`. The canary: `test/scripts/check-tla-manifest.sh` (hash, marker, model, footprint and census coverage; `--update` refuses a changed hash without an AUDIT.md entry in every named model; `ECO_TLA_CANARY=warn`), `test/tla/manifest.txt` (224 pins: 16 files, 128 `TLA-REGION` regions, 25 censuses, 54 greps), `footprint-greps.txt`, `census/`, the `tla-canary` target in ALL (top-level `CMakeLists.txt`), GC_MODEL_001 in `invariants.csv`, the CLAUDE.md line |
| 2 M2 | **model done, trace validation done (2026-09-29)**; W1/W2 PASS; canary not started | `tla-check` 33/33 in 245 s (largest 2.5 M states); deep `deep_episode` 3.0 M and `liveness_slice3` 2.9 M pass; CR-005 reproduced (`episode_stop`). Three plan predictions were wrong: `two_word` and `wrap` need three participants for a trace the code can produce (`slice3`), and `anywork_participants_only` on `help` can never fail realizably (dropped); expected-failure configs now allow only realizable give-ups. The W2 cross-check matches row for row (`priv` and the double scan are both needed under SC; the order matters under C11). Trace `gc-mark-trace`: 20/20 with 19 hooks in `MarkWork.hpp`, 44 more runs accepted; no code defect. CR-010 needs slot-range asserts (assist and closing reset foreground slots while the gang runs) |
| 3 M1 | **model and lemma done (2026-09-28)**; **trace validation done (2026-09-29)**; **W3/W4 PASS (GenMC, 2026-09-28)**; the canary not started | `tla-check`: 20/20 as expected in 55 s (M1's `MC_quick` 2,915,545 states). Deep: `ops3` 32.0M, `long` 22.0M, `wide` 36.4M, `region` 9.0M states, all pass; `CycleEnds` passes. CR-017 reproduced by TLC (`MC_quick_region`). Quick bounds had to become a per-run op budget (`MaxTotalOps`) with per-mutant operation sets (AUDIT.md). The snapshot-closure lemma is **proved inductive at 5 objects** (Apalache: base, 15 action steps, IM2 consequence; the P1 negative control fails in `OldSHClosed`); at 6 objects the base case, IM2, the negative control and 4 of 15 steps pass (run stopped; 3–4 h per step); 8 objects not feasible here. Trace validation (2026-09-29): the cycle projection and the tiny-graph traces are accepted, and they corrected M1's `Assist`; deep TLC re-run after the fix passes |
| 4 M4 | **model done (2026-09-29)**; W3/W3f/W4b PASS (GenMC); **trace validation and the TSan scenario done (2026-09-29)**; the canary not started | `tla-check`: 44/44 as expected in 180 s (largest row 875 K states). Deep: 8 rows pass (largest 10.1 M states, 4 min). TLC reproduces CR-001 (race and S1 half), CR-002, CR-014 (FATAL, silent release, `live_bytes` race) and CR-016 (stash, and retired chunk with no sweep). CR-014's FATAL needs a second size class. Fix candidates `finalize_in_lock`, `phase_atomic` + `count_until_shrink` and `tail_defers` each pass; CR-016 has no candidate. New D entry CR-027 (the 06 audit table). Wave 2: the TSan scenario `gc-heap-tsan promo` reproduces CR-001, CR-002 and CR-016 on the real allocator (CR-016 with heap corruption), not CR-014 (the tail path was never reached); trace validation 12/12 as expected on five runs (5 accept rows, 7 `mutate=` controls), and a hand-run race-detector trace config shows CR-002 in all 16 multi-threaded logs; the traces added the ladder's virgin rung to the model and removed a retry the code never does (quick 44/44 again, sweep rows ~841K → ~15K states). New entries CR-028 (validate-only V11 walk race) and CR-029 (bag-rung assert, 5/21 runs) |
| 5 M5 | **model done, trace validation done (2026-09-29)**; W1, W5 and `w_running_chain` PASS (GenMC); the canary not started | tla-check 49/49 as expected (~6 min at `--jobs 2`); deep 8/8 (largest `deep_ext` 56.4 M states, 26 min). CR-017 reproduced (`cycle_major`, `deep`) and shown for k = 2 too (`k2_cycle_major`: the fix must cover every Young extent); CR-013 reproduced 3 ways (`fork`, `fork_orphan_copy`, `fork_l3` = an L3 help/teardown hang). TenureDisjoint: `HealYoungOnly` and `MarkerDisjoint` hold everywhere; `YoungWalkValid` fails wherever majors and cycles meet. Builders, generation YLOS and k = 2 extensions done. The plan's L3 deep bounds exceeded the disk (135 M states, 50 GB); deep tier restructured. Trace validation: 27 rows as expected — the engine storm (`TraceTenuring`, `gc-tenure-trace tiny`: 5 traces, 9 controls; real loads of an earlier generation's shadow entries) and the pause projection on the real allocator (`TraceTenurePause`, `tiny_tenure.cpp`: 5 traces, 8 controls); the first real run found a model error (the engine checks `stop` before asking for an item), fixed, quick and deep re-run with the same counts. Not traced yet: L3, ageing, builders, forks |
| 6 M3 | **model done (2026-09-28)**; **trace validation done (2026-09-29)**; W5(a)/W1 PASS (GenMC); the canary not started | `tla-check` M3: 12/12 as expected in 42 s (`legacy` and `region` 225,963 states each). Deep: `legacy3` and `region3` 10.4M states each, pass; `Termination` passes. Every mutant counterexample was read against its story. Changes: the sketch's string header states broke TLC (now model values); `spineRunP`'s `needs_heads` is modelled (heap `4 = Cons(9, 5)`); the region heap keeps both YLOS parents. No protocol defect. Register: CR-019 → Confirmed (shape) by code reading; CR-014's footprint narrowed; CR-011 unchanged. Trace validation (`gc-minor-trace`, `minor_harness.cpp` tiny mode with a YLOS kind): 6 accept rows and 9 `mutate=` controls as expected, 115 more logs accepted (with lost claims, BUSY waits, lost YLOS reaches); no model or code finding. `gc-minor-tsan` with the YLOS kind: 0 TSan reports (CR-020's harness half) |
| 7 M6 + M7 | **M6 model, fork harness and trace validation done (2026-09-29)**, W `w_pool_done` and `w_running_chain` PASS; **M7 model done (2026-09-28), trace validation done (2026-09-29)**, W `w_pool_done` and W3f PASS; its canary lines not started | M6: `tla-check` 43/43 in 64 s (largest quick row 29,192 states); deep 18/18 (largest 782,327 states, 97 s). CR-003, CR-005 (a wider window), CR-015, CR-023 reproduced; CR-004's window confirmed and proposed Not-a-bug (`ChildHeapSafe` holds for every mutator fork); CR-013's window confirmed at gang level. LaunchJoin and PoolJob discharged. Step 7 recommends the fork contract (a) with its guard before `thread_mutex_`, plus CR-005's fix. Wave 2: the fork harness (`gc-fork-harness`, CR-008) reproduces CR-003, CR-004, CR-005, CR-015 and CR-023 in real code (deterministic arms 5/5; `mut`, the supported contract, 302 clean forks) and found CR-031 (a host child's `exit()` tears down the dead mutator's heap) and CR-032 (validate builds: the P1 census has no atfork handler); trace validation (`TracePool`, `TraceGangs`) 28/28 with 12 controls, including three real CR-023 logs. M7: `tla-check` 18/18 as expected in 20 s (`pw_basic` 26,496 states); deep `pw_deep` 25.5M states pass in 12 min, `pw_deep_liveness` 3.96M pass. CR-007 split: the deadlock hypothesis is Not-a-bug by M7b (the lock graph, tenure teardown's join included, is acyclic; three lock mutants deadlock); the stall is reachable (witness `lock_order_stall`); CR-025 (stall misattribution) and CR-026 (HEAP_058 wording) are new D entries. 4 mutants and `PostIdle` added for A6. Trace validation (`gc-helper-trace`, H2 fake ops and H3 real mmap, 1–4 workers): 8 accept rows and 7 `mutate=` controls as expected, 17 more runs accepted; it corrected two model steps (`reapDone` reads each slot separately; discard bodies run in batch order), after which quick is 18/18 and deep passes again |
| 8 Deep tier as a gate | **DONE (2026-09-29)** | `tla-check-deep` (48 TLC rows + 18 Apalache rows) and `genmc-check` are local gates, run in the dev container at a model's close-out and before a phase flips to default-on (§6.2); they are **not** in GitHub CI (owner's decision, 2026-09-29: a nightly workflow was drafted and removed). The master plan §2 standing rule is amended ("Keep the concurrency models in step"). Close-out run: deep TLC 48/48 (6,530 s), genmc-check 60/60 |

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
8. **Unbounded counters make the state space infinite.** M2's epoch grew without bound because
   idle markers can re-wake forever. A counter used only for equality (M2's epoch) is abstracted
   exactly by a per-observer "changed since I read it" flag, not bounded by a state constraint:
   TLC neither explores nor checks states outside a constraint, and liveness under a constraint is
   unreliable. Where a model still needs a constraint, it states it, and a configuration that hits
   the TLC time limit counts as a failure, never as a pass.
9. **Checking a model on a hand-installed toolchain.** The pins in the image are the reference.
   Results from any other tool version are not comparable, which is why Step 0 rebuilds the
   container first.
10. **A mutant that cannot fail.** The adversarial review found mutants in five plans that could
    never reach their target within their configuration's bounds (a chunk big enough that nobody
    took the lock, a wrap one minor past the bound, a victim whose deque was always empty). Every
    mutant row carries a hand-traced shortest behaviour, and TLC confirms it (§6.1).
11. **A reduced driver or model that manufactures a failure.** Dropping a read over-approximates
    for a property expected to *pass*, but can create a counterexample the code cannot produce for
    a mutant expected to *fail*. W2's decider lost the real round's second work check, and
    `w2_idle_before_publish` then "failed even under SC" when the code does not (W plan §14 R20).
12. **A model step that cannot stop where the code's can.** A model loop that must run to a fixed
    bound under-approximates the code, and model checking alone never notices, because the missing
    behaviours only make properties easier to satisfy. M1's `Assist` had to keep scanning while grey
    entries remained; the code's assist leaves when it finds no work it can take (one joined to a
    stopped control scans nothing). Trace validation found it (2026-09-29): real runs with an assist,
    a fork stop and a relaunch were rejected. Give every loop the exits the code has.
13. **A pgrep that matches itself.** `while pgrep -f 'X'` in a shell whose own command line contains
    `X` never ends. Use `pgrep -f '[X]…'` or wait on a PID. It stalled one model track for an hour
    (2026-09-28).

## 13. Adversarial review of the model plans (2026-09-28)

Before implementation, each model plan had an adversarial review against the current tree. One
reviewer per plan read the code the plan cites, checked every abstraction and step against it,
hand-traced every mutant against its bounds, and corrected the plan in place. The orchestrator
verified the key claims, reconciled conflicts between reviews, and made the cross-cutting changes.
Each plan's last section has its full table. **TLC, Apalache and the C11 checkers were not run**:
every expected outcome is still a prediction. Every corrected PlusCal sketch passes `pcal` and SANY,
and the W drivers compile with g++ and clang++ against the real headers.

| Plan | Blocker / Major rows | Headline corrections | Register |
|---|---|---|---|
| M1 | 1 / 5 | region mode (the default) was invisible: the t0 walk reads dead hand-over objects (`RegionMode`, `zombie`, `quick_region`, `quick_region_nomajor`); the handoff frees unmarked YLOS cells (`CellObjs`); the pressure check comes before the step; §4.7's `LemmaInv` was not inductive and Apalache rejects the recursive `Reach` | CR-017 (new) |
| M2 | 2 / 7 | two mutants and `wrap` could never fail; `anyWork` split into a deque step and a `priv` step; the epoch's state constraint replaced by exact `dirty` flags; asserts became `AssistExact`, `ClosingFinished`; `Drain` is a named invariant | CR-005 reproduced by hand trace |
| M3 | 2 / 5 | `ylos_unlocked` and `heads_walk` could never fail on the example heap; `CopyOnceContract` stated; canonical copy ids replace a global counter | CR-019, CR-020 (new); CR-011, CR-014 |
| M4 | 6 / 7 | only one worker could ever reach the lock (CR-001/002 unreachable); the free list was FIFO (code: LIFO); the detector now uses vector clocks with word-wide reads; one configuration per register entry; CR-016 modelled | CR-018, CR-022 (new); CR-001, CR-002 (now Confirmed), CR-014, CR-016 |
| M5 | 2 / 7 | two mutants could not reach their targets within the bounds; asserts became named invariants; `HealYoungOnly`, `MarkerDisjoint`, `YoungWalkValid` provide TenureDisjoint to M1 | CR-013, CR-017 |
| M6 | 2 / 8 | the `exit` configuration would have failed (exit now runs on the mutator); missing `Alive` guards; LaunchJoin and PoolJob stated as named invariants; the wait holds the lock between check and block | CR-023, CR-024 (new); CR-003, CR-004, CR-005, CR-013, CR-015, CR-008 |
| M7 | 1 / 9 | aging was deterministic and major-only, so trace validation would reject real traces; the lock model lacked the tenure teardown edge; a stall witness for CR-007 | CR-007, CR-012 |
| W | 3 / 11 | four negative controls could not fire (W4's order was reversed, W5's help never read through, W1 needed two thieves, W2's mutant patched code the driver does not run); feasibility traps in the drivers; a coverage census; the two-scan decider (R20) | CR-021, CR-022 (new); CR-002, CR-009 |

**Cross-cutting changes:**
- §5.0: every contract names the invariants that discharge it; new contracts TenureDisjoint (M5 →
  M1), PoolJob (M6 → M7), BitFaithful (M4 → M1, M5) and ReleaseContract (M4 → M7); M4 no longer
  claims to use SnapshotCycle or CopyOnce.
- §5.1: the expected failures name their configurations; CR-017 joins them.
- §6.1: named invariants instead of asserts, one target per mutant configuration, witness
  configurations, and a per-model time budget.
- A8 and trap 8: exact abstraction of equality-only counters instead of state constraints.
- The primer gained rules 12–13 (Apalache and recursion; unprimed variables in `define`
  operators), the per-location `anyWork` rule, the vector-clock race detector, the lock-holding
  wait, `Alive` guards, and the mutant rules.

**Most urgent code findings** (full entries in the register): CR-018 (serial S1: an empty-block flip
over live objects after the sweep, at any geometry, for an allocation of exactly
`alloc_buffer_size` bytes), CR-017 (region mode, the default: the t0 walk can grey freed cells after a
STW major), and CR-014 (now also a `live_bytes` race and a `large_body_index_` map race).
