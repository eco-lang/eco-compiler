# MLIR split backend 00: spikes, measurements and censuses (de-risk first)

**Master plan:** `plans/mlir-split-backend.md`. **Status:** written and completed 2026-10-02. All spikes GO; results in §8.

This plan collects every spike, measurement and census from plans 01–04 and from the master
plan's go/no-go spike. None of it changes generated code. Every new hook is diagnostic, sits
behind an environment variable, and costs nothing when that variable is unset. The goal is to
test each child plan's riskiest assumption before any production code is written.

Each spike has a **go/no-go** outcome. "No-go" stops, or re-scopes, the plan that depends on it.

## 1. Sources

| Plan | Pulled from | Riskiest assumption under test |
|---|---|---|
| master | M1 (the old M3) | Each LPT partition can be built as its own MLIR module and translated in parallel into its own LLVMContext. This must be thread-safe and fast, with acceptable memory. |
| 01 cap-hoist | §7 M1–M8, S0 | Phases A–C, computed on the llvm-dialect MLIR, reproduce LLVM's coverage, budget and ⊤ decisions (the seven emulations). |
| 02 gc-leaf | §6 M1–M7 | An MLIR poison fixpoint reproduces LLVM's stamped set (MLIR ⊆ LLVM), given the marker table and 01's coverage. |
| 03 reachability | §8 M1–M5, step 1 | MLIR reachability from `main` and `__eco_init_globals` equals the set that survives LLVM's GlobalDCE, and the address-taken rule matches `hasAddressTaken`. |
| 04 thunks | Step 0, phase-2 hazard | The hot thunks have the expected closed scalar bodies. Phase-2 substitution can be emitted without a let-name collision. |

## 2. Infrastructure

**I1. `EcoSpikeCensus`.**
- New file `runtime/src/codegen/SpikeCensus.cpp`, called from `eco-boot.cpp` on the final
  llvm-dialect module, just before translation.
- Runs only when `ECO_SPIKE_DIR=<dir>` is set. It writes TSV files into that directory and
  never modifies the module.
- **Shared core:**
  - a parallel per-top-level-op collection of the symbol graph: edges classified as call,
    `addressof`-then-call with matching type, `addressof`-then-call with mismatched type,
    other `addressof`, or attribute reference;
  - `llvm.call` sites and their callees;
  - `__eco_alloc_inline` marker sizes;
  - per-function CFG cycle membership, reachable from the entry block;
  - gc-leaf passthrough on each callee.
- Everything is timed with `std::chrono` and printed as `[spike]` lines.

**I2. LLVM-side oracles** (`EcoBackend.cpp`, also env-gated):
- `ECO_CAPHOIST_FULL_DUMP=<file>`: every defined function as
  `name;top;reason;budget;ownBytes;eligible;addrTaken;local;covered`.
- Stats scopes for Phases A, B+C, D and D2. They show in the `--lowering-stats` banner.
- A Phase D counter for runs broken by a call to a budget-0 generated callee (`[caphoist-spike]`).
- `ECO_GCFREE_LEAF_DUMP` already exists and writes the stamped set.

**I3. Analysis scripts** in `stats-backend-opt/spikes/` (Python). They join the MLIR TSVs
with the LLVM oracles and print the result tables.

## 3. SP1: parallel partition translation (master go/no-go)

`ECO_SPIKE_PARTITION_TRANSLATE=1`, alongside `ECO_SPIKE_DIR`.
1. **Partitioning.** LPT over defined `llvm.func` ops, weighted by op count, into N = 24
   partitions. Each global goes to the partition of its first referrer.
2. **Building the partition modules, in parallel.** Each partition gets a fresh `ModuleOp`
   holding:
   - its owned functions, cloned;
   - its owned globals, cloned;
   - every other referenced symbol as an external declaration: functions via
     `cloneWithoutRegions`, keeping attributes; globals without their initializer.
3. **Translation, in parallel.** `translateModuleToLLVMIR` on each module, each with its own
   `LLVMContext`, then `llvm::verifyModule` on each result.
4. **Report:**
   - build time, translation time and total wall;
   - Σ function and global counts compared with the single module;
   - verify failures;
   - peak RSS (`getrusage`);
   - optionally (01-M8) the same with a passthrough string attribute stamped on every function,
     to price attribute translation.

**Go:** no crash, all modules verify, counts match, and wall time is well below the 6.7 s
serial translation, with RSS growth under 2 GB.
**No-go:** thread-safety failures that can't be avoided, or no wall gain. That would put the
whole master plan in question.

## 4. SP2: cap-hoist Phases A–C on MLIR (plan 01)

**The spike.** The census emulates Phase A on the MLIR module:
- marker sizes;
- markers inside entry-reachable CFG cycles;
- calls:
  - **leaf:** gc-leaf passthrough or a marker-table leaf;
  - **⊤:** headroom breakers, indirect calls, non-leaf declarations;
  - **callee edge:** a defined callee, with an in-loop flag;
- eligibility: not a root, not address-taken, not interposable.

It then runs Phase B (Tarjan, the same rules, K) and Phase C, and dumps
`name;top;budget;ownBytes;eligible;addrTaken;covered`. A script diffs this against
`ECO_CAPHOIST_FULL_DUMP` for the functions present in both, and buckets every difference by
cause.

**Measurements:**

| ID | Measures | Comes from |
|---|---|---|
| 01-M1 | The A / B+C / D / D2 time split | I2 stats scopes |
| 01-M2 | The `[caphoist]` line at HEAD | `ECO_ALLOC_HOIST=1` arm |
| 01-M3 | Counts: matched and mismatched `addressof` calls; calls that are leaf only through TLI or as intrinsics; list-tail, value-eq, sat and cursor marker sites; scratch-helper call sites; expansion-side function-type mismatches | MLIR census plus a pre-RS4GC `.ll` scan |
| 01-M4 | Markers and calls in unreachable blocks, on MLIR and on LLVM. Does translation keep unreachable blocks? | census |
| 01-M5 | Covered `$cap`s; directly called `$cap`s per LPT partition; nested `$cap` depth | census + SP1 partitioning |
| 01-M6 | Phase D runs broken by calls to budget-0 generated callees | I2 counter |
| 01-M7 | MLIR-vs-LLVM defined set and address-taken differences | SP2 + SP4 joint |
| 01-M8 | Translation cost of about 50k passthrough string attributes | SP1 option |

**Go:** after the emulations, coverage and budgets agree for every common function except
explained buckets that a rule can fix. **No-go:** an unexplained or unfixable class of
differences.

## 5. SP3: gc-free propagation on MLIR (plan 02)

**The spike.** On the same facts, run an optimistic poison worklist:
- **seeds:** indirect calls, non-leaf declarations, marker-table rows (final view);
- **leaf:** the `__eco_alloc_inline` slow path only when the marker is unchecked, that is,
  when its function is covered by SP2's emulation.

Dump `S_mlir`, and compare it with `ECO_GCFREE_LEAF_DUMP` (`S_llvm`) under default hoisting
and under `ECO_ALLOC_HOIST=0`. Report |S_mlir \ S_llvm| (must be 0: MLIR stamping something
LLVM doesn't would be unsafe) and |S_llvm \ S_mlir| (lost precision), bucketed by cause.

**Measurements:**

| ID | Measures | Comes from |
|---|---|---|
| 02-M1 | S_llvm with hoisting on and with `ECO_ALLOC_HOIST=0` | dumps |
| 02-M2a | Cursor-marker functions in S_llvm | census join |
| 02-M2b | `addressof` calls (in S_llvm functions) that become direct in LLVM | census join |
| 02-M2c | Calls that are leaf only through TLI | `.ll` scan |
| 02-M2d | Scratch-helper calls in S_llvm functions | census join |
| 02-M2e | List-tail and sat markers in otherwise-free functions | census join |
| 02-M2f | `__eco_value_eq` sites; does `Elm_Kernel_Utils_equal` survive? | census |
| 02-M3 | S_llvm ∩ ⊤ and S_llvm ∩ covered | joins with the I2 dump |
| 02-M4 | Stamped functions with a caller in another partition; stamps that depend only on a cross-partition callee | SP1 partitioning + census graph |
| 02-M5 | Phase D breakers that are calls to budget-0 functions in S_llvm | I2 counter |
| 02-M6 | S_llvm with `ECO_CAP_INLINE_MAX_INSTS=0` against the default | two dumps |
| 02-M7 | Type-mismatched `addressof` calls to gc-leaf declarations | census |

**Go:** S_mlir \ S_llvm = ∅, with a small and explained precision loss. **No-go:** any
unexplained element of S_mlir \ S_llvm.

## 6. SP4: reachability census (plan 03)

| ID | Measures | How |
|---|---|---|
| 03-M1 | Dead census | `-O0 --emit=obj` against `--emit=exe`, both with `--dump-pre-rs4gc-ir`. Diff the defined, declared and global name sets and bucket them by name pattern. |
| 03-M2 | `addressof` with no uses; `addressof` used only by unused constant-foldable ops; `addressof`-then-call with matched or mismatched type | census |
| 03-M3 | (op name, attribute name) pairs holding a non-inherent SymbolRefAttr | census |
| 03-M4 | Collection, BFS and RSS cost | census timers |
| 03-M5 | `eco_gc_add_root` calls in `__eco_init_globals` | `.ll` grep |
| 03-S1 | The census BFS's reached set against the LLVM GlobalDCE survivors (the exe dump) | script |

**Go:** reached set == the GlobalDCE survivors (or a superset explained by named rules); no
phantom attribute edges outside `callee` / `global_name`.

## 7. SP5: constant thunks (plan 04)

| ID | Measures | How |
|---|---|---|
| 04-S0.1 | The final bodies of the hot thunks: `hashBase`, `Array.shiftStep`, `branchFactor`, `bitMask`. Is `logBase` inlined? Which let-names do they bind, and which callee forms appear? | Print those functions from the self-compile's eco-dialect MLIR, `ecoGCR.mlir`, which is final codegen output |
| 04-S0.2 | Arity-0 scalar functions classified by body (literal, alias, closed scalar expression, other), with reference counts, weighted by the IPO perf rows | census over `ecoGCR.mlir` |
| 04-S0.3 | The prologue-off configuration under E2E | Small test programs stay under the 4,000-function split threshold, so the prologue never runs for them. The only exercising workload is the self-compile, whose fixed point already held with the prologue off (3/3, IPO entry). Record this as covered, with the reason. |
| 04-S0.4 | Phase-2 substitution prototype | Emit a closed thunk body inline at a reference site whose caller binds the same let-name. Check that the MLIR is valid and the result correct, using the JS front-end dev loop (`eco-boot.js`, memory `eco-fast-compiler-dev-loop`) on a small program |

**Go:** the hot thunks are closed scalar bodies, and phase 1 or 2A can fold them. The
substitution prototype shows the let-name hazard is real and that a fresh scope fixes it.
**No-go:** the bodies are not closed (they call non-inlined functions), so plan 04 needs a
different mechanism.

## 8. Results (2026-10-02)

Everything ran on `ecoGCR.mlir` with the `keep-B4` tree plus the diagnostic hooks.

**Hooks and where they live:**
- `runtime/src/codegen/SpikeCensus.{h,cpp}`, called from `eco-boot.cpp` before translation.
- `EcoBackend.cpp`: `ECO_CAPHOIST_FULL_DUMP`, `ECO_GCFREE_ALL_DUMP`, `[caphoist-spike]` and
  `ECO_SPIKE_THUNK_FOLD`.
- Scripts in `stats-backend-opt/spikes/`: `analyze.py`, `joins02.py`, `deadcensus.py`,
  `thunks.py`.
- Raw outputs in `stats-backend-opt/spikes/run{1,2,3,3-nohoist,3-capinl0,4}/`.

### Verdicts

| Spike | Verdict | One line |
|---|---|---|
| SP1 parallel partition translation (master go/no-go) | **GO** | 24 MLIR partition modules, 0.16 s to build, **0.67 s to translate in parallel** (6.7 s serially); 0 failures; all verify; counts identical |
| SP2 cap-hoist A–C on MLIR (plan 01) | **GO** | **Exact match** with LLVM on top, budget, own bytes, eligible, address-taken and covered, for all 75,775 functions (5,923 covered on both sides) |
| SP3 gc-free on MLIR (plan 02) | **GO** | **Exact match** on every function defined at gc-free time. MLIR stamps nothing extra and loses nothing. With `$cap` inlining off, 9,459 = 9,459 |
| SP4 reachability on MLIR (plan 03) | **GO** | Reached set = the LLVM internalize + GlobalDCE survivors **exactly** (75,775), with zero phantom attribute edges |
| SP5 constant thunks (plan 04) | **GO** | The hot thunks are a literal (`hashBase`, `branchFactor`) and closed scalar bodies (`shiftStep`, `bitMask`). An LLVM emulation of phase 1+2 with the prologue OFF self-compiles in 107.28 s, against 109.58 OFF and 108.10 ON |

### SP1: parallel partition translation

| Measure | Value |
|---|---|
| Build 24 partition modules (parallel clone + declarations) | 0.16 s (0.14 s in a repeat) |
| Translate, parallel wall (slowest partition) | **0.67 s**, against 6.7 s serial |
| Translation failures / `verifyModule` failures | 0 / 0 |
| Defined functions across partitions | 98,163 = single module; 52,193 defined globals |
| Block count per function, MLIR against LLVM | 0 mismatches out of 98,163 (translation keeps every block; there are no unreachable blocks) |
| RSS | +1.0 GB for building, +0.7 GB for translating. The spike keeps the single-module path alive too, so these are upper bounds |
| 01-M8: a `key=value` passthrough string on every function | translation wall 0.67 → 0.85 s (+0.18 s, parallel) |

### SP2: capacity hoisting (plan 01)

- The first run mismatched on 581 ⊤ decisions. The **cause was the census using K = 4096 while
  LLVM's default is 512** (`capHoistMaxBytes`). With the same K the match is exact. Lesson: the
  MLIR plan pass must read K from the same helper, or stamp it into the plan.
- **01-M1, phase split (serial, s):** A 0.47 · B+C 0.014 · D 0.29 · D2 0.20. Only A, about 0.47 s,
  plus the 0.014 s of B+C leaves the per-partition path. D and D2 stay per partition.
- **01-M2, `[caphoist]` at HEAD:**
  - coverable 5,923 of 75,775; sites 16,871;
  - runs 33,178; folded markers 48,010; unchecked 48,010;
  - excluded: address-taken 7,899, linkage 0, loop 880, cycle 1,681, budget 469, other 55,387;
  - K = 512.
- **01-M3, call and marker counts:**
  - list-tail 5,442; sat 22,963; value-eq 1,932; cursor 9,389; scratch helpers 1,224;
  - **TLI-only leaf calls 0**;
  - `addressof` calls: 4,360 with matching type, **9,900 with mismatched type**, 0 mismatched to
    a gc-leaf declaration.
  - Expansion-side function-type mismatches: subsumed. LLVM's decisions are taken after the
    expansions, and the match is still exact.
- **01-M4:** 0 unreachable blocks or markers; translation preserves block counts.
- **01-M5, `$cap`:**
  - 19,784 defined; 924 covered; 10,233 directly called;
  - **1,328–1,386 directly called `$cap` bodies per partition are owned elsewhere**, which is
    the copy cost (about 1,366 average);
  - nested `$cap` depth at most 2.
- **01-M6:** 8,742 Phase D run breaks by calls to budget-0 generated callees, over 1,583 callees.
- **01-M7:** address-taken (live) and eligibility differences: **0**.

### SP3: gc-free propagation (plan 02)

- **02-M1:** S_llvm has 8,558 functions with hoisting on, and 3,485 with `ECO_ALLOC_HOIST=0`.
- **Validate result:** among functions still defined at gc-free time, MLIR \ LLVM = 0 and
  LLVM \ MLIR = 0. The 901 MLIR-only names are all `$cap` bodies that the inline prepass
  **deletes** before gc-free runs. With `ECO_CAP_INLINE_MAX_INSTS=0` the sets are identical
  (9,459). **02-M6:** no function becomes GC-free only through inlining.
- **02-M2a:** 263 S_llvm functions hold cursor markers (598 sites). The marker table needs the
  cursor rows marked leaf; that is a precision issue, not a safety one.
- **02-M2b:** 48 S_llvm functions have `addressof` calls that become direct in LLVM (49 sites).
- **02-M2c:** 0 TLI-only leaf calls.
- **02-M2d:** 5 S_llvm functions call scratch helpers (7 sites).
- **02-M2e:** 0 list-tail, sat or value-eq markers in S_llvm, as predicted.
- **02-M2f:** 1,932 value-eq sites. **`Elm_Kernel_Utils_equal` is absent from the final
  MLIR**: the unused-decl strip removes it. The LLVM expansion re-creates it with
  `getOrInsertFunction` and no gc-leaf, so value-eq is non-leaf today. This confirms the
  per-partition leafness hazard the review found: the table must not depend on whether the
  declaration survived.
- **02-M3:** S_llvm ∩ ⊤ = 0; S_llvm ∩ covered = 5,073; S_llvm with budget 0 = 3,485.
- **02-M4:** **93 % of call edges cross partitions** (89,311 of 95,798 at N = 24 LPT).
  7,415 GC-free functions have a caller in another partition, and 3,979 have a callee in another
  partition. Cross-partition attribute copying is the normal case, not an edge case.
- **02-M5:** 8,634 of the 8,742 Phase D breaks (1,533 callees) are calls to budget-0 callees
  that LLVM later stamps gc-leaf. **This is the size of the 01/02 ordering hazard:** if stamps
  reached hoisting first, those runs would change.
- **02-M7:** 0 mismatched-type `addressof` calls to gc-leaf declarations.

### SP4: reachability (plan 03)

- **03-S1:** MLIR reached = 75,775 = the LLVM survivors. Reached \ LLVM = 0 and LLVM \ reached = 0.
- **03-M1, what the exe-only DCE removes:**
  - 22,388 defined functions: 12,138 specs, 10,233 `$clo` closure variants, 17 kernel wrappers;
  - 1 runtime declaration;
  - 44 eval-layout globals.
- **03-M2:** 0 unused `addressof` ops; matched and mismatched `addressof` calls as in 01-M3.
- **03-M3:** **0** non-inherent SymbolRefAttr kinds. Only `callee` and `global_name` reference
  symbols.
- **03-M4, cost:**
  - parallel collection 0.36–0.38 s;
  - BFS 0.009 s;
  - Phase B+C emulation 0.017 s;
  - gc fixpoint 0.011 s;
  - whole census 0.55–0.57 s;
  - no measurable RSS growth.
- **03-M5:** 0 `eco_gc_add_root` calls in `__eco_init_globals`. Its only call is
  `eco_register_type_graph`, which confirms plan 03's "root pruning is moot".

### SP5: constant thunks (plan 04)

- **04-S0.1, bodies** (from `ecoc --emit=mlir` of `ecoGCR.mlir`; `ecoc` writes that text to
  stderr):
  - `hashBase`: `arith.constant 67108864; eco.return`, a literal.
  - `branchFactor`: `arith.constant 32`, a literal.
  - `shiftStep`: `eco.call @branchFactor; eco.int.toFloat; eco.float.log ×2; eco.float.div;
    eco.float.ceiling`. **`logBase` is inlined**; the body is closed over a literal thunk.
  - `bitMask`: `32 - eco.call @shiftStep; eco.int.shru …4294967295`, closed.
- **04-S0.2, census:** only **49** arity-0 scalar functions exist.

  | class | functions | direct reference sites | perf samples (prologue off) |
  |---|---|---|---|
  | literal | 42 | 556 | 119 |
  | closed scalar | 3 | 336 | 380 |
  | other (Char/String reporting glyphs) | 4 | 6 | 0 |

  There are 0 `papCreate` references.
- **04-S0.3, prologue-off under E2E:** covered by reasoning. Test programs sit below the
  4,000-function split threshold, so the prologue never runs for them. The self-compile with
  the prologue off reproduced the fixed point 3 out of 3 times (IPO entry), and 3 more times in
  SP5's runs below.
- **04-S0.4, phase value, re-scoped to an LLVM-level emulation:**
  - `ECO_SPIKE_THUNK_FOLD=1` replaces calls to literal thunks with their constant: phase 1, 43
    thunks and 558 calls.
  - `=2` also constant-folds closed thunk bodies: phase 1+2, 45 thunks and 893 calls.
  - Both run before the prologue point, with the prologue OFF, and are compared against
    prologue ON and OFF. The self-compile times are in the next block.
  - The let-name collision hazard of an Elm-side phase-2 prototype was **not** prototyped.
    That needs the phase-2 codegen itself; it stays plan 04's first implementation step, with
    the pinning test.

**04-S0.4 result.** Self-compile wall in seconds. Four arms, 3 interleaved runs each, all at
the fixed point:

| arm | r1 | r2 | r3 | median |
|---|---|---|---|---|
| prologue ON (today) | 110.43 | 108.10 | 106.63 | 108.10 (wide spread) |
| prologue OFF | 109.04 | 109.67 | 109.58 | 109.58 |
| OFF + phase 1 (literal thunks) | 108.22 | 109.01 | 108.62 | 108.62 |
| OFF + phase 1+2 (closed bodies folded too) | 107.93 | 107.28 | 106.95 | **107.28** |

- **Phase 1 alone recovers about 2/3** of the prologue's value: −0.96 s against OFF, with
  barely disjoint ranges.
- **Phase 1+2 recovers all of it and slightly beats the prologue:** −2.30 s against OFF
  (disjoint ranges), −0.82 s against ON's median. This is the "folding deletes the call"
  effect plan 04 predicted, though ON's spread is wide.
- **Verdict:** plan 04 is GO with **both phases**. Phase 2 is worth about 1.3 s, and its only
  open hazard is the codegen let-name scoping, which is implementation work with a known fix.
- Dropping the cgu prologue after plan 04 is supported: OFF + phase 1+2 ≤ ON.
