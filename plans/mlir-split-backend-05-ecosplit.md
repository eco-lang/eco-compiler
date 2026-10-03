# MLIR split backend 05: EcoSplit — partition in MLIR, translate and lower in parallel

**Master plan:** `plans/mlir-split-backend.md` §2 (target pipeline), §4 (the split), milestone M6.
**Status:** IMPLEMENTED 2026-10-02 and default-on; the lazy bitcode split is retired (results in
"Implementation results" at the end). Part I is the design, corrected by the adversarial review
at the end of Part I; Part II is the build specification.
**Prerequisites (all landed 2026-10-02):** 01 (cap-hoist plan in MLIR), 02 (gc-leaf stamps in
MLIR), 03 (reachability + `EcoSymbolGraph`), 04 (constant thunks; IPSCCP prologue deleted).
**Spike:** plan 00 SP1 — 24 MLIR partitions built in 0.16 s and translated in parallel in 0.67 s
(6.7 s serially), 0 failures. That ran on the pre-03 module, without import copies or exports
and with no other LLVM work running, so treat it as a lower bound.

`EB` = `runtime/src/codegen/EcoBackend.cpp`. `P/` = `runtime/src/codegen/Passes/`.

# Part I: design

## 0. Goal and verdict

**Today** (SPL entry, `benchmarks/backend-opt-loop.md`, 38.61 s wall):
- one `llvm::Module` is translated serially (6.30 s);
- the whole-module pre-RS4GC steps run serially (~3.0 s);
- the module is externalized and serialized to bitcode once (3.64 s);
- every worker lazily re-parses and extracts its partition (8.44 s CPU);
- the MLIR teardown is a serial 1.17 s (TL).

With 01–04 landed, no step before RS4GC needs the whole program: every whole-program fact is
computed in MLIR and carried as attributes or module flags. So the partitioning moves in front
of translation:

```
MLIR pipeline … EcoTailConversions → EcoReachability → EcoCapHoistPlan → EcoGcFreePropagation
EcoSplit (driver): owners, imports, exports, partition modules (parallel clone), S6 check
per partition, in parallel (std::thread; own LLVMContext + TargetMachine):
  translate → rename main → finishReachability → runEcoBackend(partition-worker job):
    expansions → plan-given hoisting → expandInlineAllocs → root ranges → $sat
    → export cross-referenced functions → $cap prepass → drop import copies
    → gc-free finish → externalize locals → assert no available_externally
    → RS4GC (+ asserts) → per-partition opt → emit
join: (X) gc-leaf join; link (exe) or ld -r (obj)
```

**Expected wall:** ~28–31 s (from 38.6 s). The serial translation (6.3 s), the serial pre-RS4GC
block (3.0 s), the serialize (3.6 s) and the re-parse leave the critical path. Added costs: the
split (~0.3–0.6 s), the teardown (moved off the critical path if possible), and about 32.8k
import-copy bodies translated, expanded and hoisted inside the workers.

**Feasible.** The work is mostly plumbing around code that already exists:
- SP1's partition builder, corrected;
- `runEcoBackend`'s single-partition path, in an explicit partition-worker mode;
- the (X) join from 02;
- the symbol graph from 03.

## 1. Findings that shape the design

1. **A partition worker is `runEcoBackend` in a dedicated mode.**
   - The single-object path already runs every pre-RS4GC step and then, for `cgu`/`dev`, RS4GC
     + `optimizePartitionModule` + emit inline.
   - It is reached with `splitEligible = true` (which enables the parallel tier) and
     `splitCodegen = 1`, which forces `choosePartitionCount` → 1. `splitEligible = false` would
     **not** work: it disables the parallel tier, so dev gets the full -O2 (review R1).
   - The worker creates its own TargetMachine, at the dev emit level under dev, **before**
     `runEcoBackend`. The expansions build their TLI from the module triple, which
     `createEcoTargetMachine` sets.
2. **One whole-module fact hides in an expansion gate.** `expandGetTagMarkers` emits the
   `Tag_ConsChunk` compare only if `eco_enable_list_chunks` is declared **and used** (`EB` ~2664).
   EcoToLLVM injects that call into `main` only (`P/EcoToLLVM.cpp` 224-241), so every partition
   but `main`'s would silently drop the compare. Carried as the module flag `eco-list-chunks`.
   The review's full audit (R13) found no other gate.
3. **The `$cap` prepass inlines across what become partition boundaries.**
   - **Imports:** a caller in P of a `$cap` owned by Q needs Q's body to inline it. EcoSplit
     imports an `available_externally` copy into P: the closure over `Call`-bit edges into
     `$cap` definitions owned elsewhere, followed through the copies (nesting ≤ 2; plan 00 counted
     1,328–1,386 per partition).
     - A **missed import** costs only performance: the caller keeps a declaration, which carries
       the facts.
     - A **missed export** is the link-error case.
   - **Exports:** a `$cap` owned by P, internal, whose P-local calls were all inlined, would be
     deleted by AlwaysInliner while Q still references it. So owned functions referenced from
     another partition become External + hidden before the prepass.
   - **Drop:** every copy left after the prepass becomes a declaration again. That is
     unconditional (also at `-O0`, where the prepass is skipped). A hard error then checks that
     no `available_externally` function reaches RS4GC (02 F8 / E1.4; review R3).
   - **No imports** when the prepass will not run (`-O0`, `ECO_CAP_INLINE_MAX_INSTS=0`;
     review R5).
4. **01's local verification must accept an `available_externally` covered copy.** It is a copy
   of a verified owner. Census counters must count owned definitions only (review R12).
5. **Late externalization is kept.** `externalizeAllLocals` runs per partition at the old point
   (after gc-free, before RS4GC), so per-partition `-O2` sees today's all-hidden linkage.
   **Deliberate deviation from master §4.3**, which proposed internal linkage for
   partition-local symbols: that re-enables intra-partition IPO and is left for a later,
   separately measured step (review R21). Unnamed globals are asserted absent, because the
   per-partition `__eco_lazysplit` names would collide (review R16).
6. **01 S6 is mandatory** (review R2). EcoSplit hard-errors when any declaration's or import
   copy's `eco-cap-*` entries differ from its owner's. Since EcoSplit clones from the owner op
   this holds by construction, and the check makes it a release-build invariant against future
   edits. A fault-injection hook (`ECO_SPLIT_FAULT_DROP_COVERED`) proves the check fires.
7. **Whole-module twins and oracles do not run per partition** (review R11, R20):
   - 01's compute-mode twin;
   - 02's gc-free twin, which per partition can no longer check cross-partition edges;
   - 03's LLVM-DCE oracle and the `hasAddressTaken` cross-check.

   In partition mode they are bypassed explicitly. The old whole-module path, which runs
   them, stays available behind `ECO_MLIR_SPLIT=0`.
8. **Not byte-identical to the lazy split.** Ownership comes from MLIR op counts, so per-partition
   `-O2` sees different neighbours. Correctness gate G2 compares every function's pre-RS4GC IR
   between the paths, under a specified normalizer (review R10).
9. **Modes** (review R4). EcoSplit runs only for EmitObjectFile with `parallelOpt ∈ {cgu, dev}`,
   no `rs4gcAfterOpt`, a multithreaded MLIRContext, and N > 1.
   - `--parallel-opt=none`, `--rs4gc-after-opt`, Win32 (single-threaded context) and
     `ECO_MLIR_SPLIT=0` keep the existing translate-whole path. That path uses
     `emitObjectFilesSplit` (SplitModule) when it splits.
   - **Retired:** the lazy path (`emitObjectFilesSplitLazy`: externalize + serialize once +
     per-worker lazy re-parse) and its `--lazy-split` default.
10. **Diagnostics** (review R9). Every file a worker writes gets a `.p<N>` suffix: RS4GC dumps,
    `ECO_GCFREE_LEAF_DUMP`, `ECO_GCFREE_ALL_DUMP`, `ECO_ALLOC_HOIST_DUMP`, `ECO_CAPHOIST_FULL_DUMP`
    and `.breakers`. This uses a thread-local partition index. Stats scopes keep their names; under
    split the "(serial)" phases are sums over workers, and that is noted in the stats banner.
11. **MLIR lifetime** (review R7, R8).
    - The dialect translations are registered once, before any thread starts.
    - The source module is destroyed on a helper thread concurrently with the workers.
    - Each partition's MLIR module is freed in its worker right after translation.
    - The MLIRContext outlives all of them.

## 2. Ownership, imports, exports, linkage

- **Functions:** LPT by op count (cost descending, then name). N comes from the shared policy
  applied to the MLIR defined-function count. Review R19 noted that import-copy cost is not
  counted in the balance; G5 measures the imbalance.
- **Globals:** the partition of the first referrer in module order. Unreferenced globals (roots,
  extra roots) go to partition 0.
- **Imports:** described in §1.3. Imports are only `$cap`-named functions, and only through the
  `Call` bit (review R15).
- **Declarations:** every symbol referenced by an owned definition or an import copy that the
  partition does not own, cloned without regions, all attributes kept (as today's `deleteBody`),
  linkage External. Globals lose their initializer.
- **Order:** owned definitions and copies keep their original relative module order (G2:
  AlwaysInliner's nested result depends on order). Declarations come first.
- **Module level:** `llvm.module_flags` goes into every partition, plus `eco-list-chunks` when
  set. Any other non-symbol top-level op goes into partition 0. Module attributes (data layout,
  triple) are copied.
- **Exports:** owned functions referenced from another partition (in-edges from other owners or
  from import copies).

## 3. Risks

| Risk | Mitigation |
|---|---|
| A whole-module gate is missed (silent wrong code) | R13 audit; G2 per-function IR identity |
| Missed export → link error (loud) | export = all cross-referenced owned functions; late externalize covers globals; G3/G4 |
| Missed import → lost inline (perf only) | census asserts imports = `Call`-closure; G2 shows any lost inline |
| Stale copy statepointed and inlined post-RS4GC (GC miscompile) | unconditional drop; hard error before RS4GC |
| `eco-cap-*` mismatch across partitions (heap corruption) | S6 hard error in EcoSplit; fault-injection proof |
| Shared MLIRContext concurrency | registration once; multithreaded-context gate; G8 TSan smoke |
| RSS | source teardown concurrent; partitions freed after translate; measured in G5 |
| Codegen change from partition assignment | recursive tax ≤ 3 % (G6) |

## Adversarial review (2026-10-02)

An independent read-only review (an agent with only the plan and the tree) found 22 issues. The
design above is corrected in place.

| # | Severity | Issue | Fix |
|---|---|---|---|
| R1 | high | `splitEligible = false` disables the parallel tier (`EB` 4362-4365): dev gets full -O2, dev emit level ignored; `splitEligible = true` with auto `splitCodegen` re-splits inside a worker | partition-worker mode: `splitEligible = true`, `splitCodegen = 1`, own TM at the tier's emit level, created before `runEcoBackend` (§1.1) |
| R2 | high | 01 S6 (mandatory `eco-cap-*` presence/equality at split time) missing | EcoSplit hard error + fault-injection proof (§1.6) |
| R3 | high | `checkStampedBodies` rejects `available_externally` only on stamped functions, in stamp mode | new mode-independent hard error before RS4GC (§1.3) |
| R4 | high | the modes served by the split emitters (none, -O0, rs4gcAfterOpt, dumps) not stated; deleting them would serialize those | explicit mode gate; keep `emitObjectFilesSplit`, retire only the lazy path (§1.9) |
| R5 | med | -O0 / `MAX_INSTS=0`: copies never inlined; stamped copies would hit `checkStampedBodies` | no imports then; drop unconditional (§1.3) |
| R6 | med | SP1 builder externalizes owned locals at build time and puts module flags in partition 0 only | keep MLIR linkage; module flags everywhere (§2) |
| R7 | med | translation registration per call mutates the registry concurrently; Win32 single-threaded context | register once; gate on multithreading (§1.11) |
| R8 | med | MLIR module alive alongside the workers (RSS); teardown cost not counted | concurrent teardown; per-partition free; measured (§1.11) |
| R9 | med | N threads truncate the same dump files | `.p<N>` suffixes (§1.10) |
| R10 | med | G2 cannot pass naively (order dependence, hidden vs internal, numbering, surviving exported dead `$cap`s) | keep module order; specify the normalizer; compare defined sets separately (Part II) |
| R11 | med | the 02 twin weakens silently per partition | bypassed in partition mode (§1.7) |
| R12 | med | `[caphoist]` / `[gcfree]` counters include copies; lines interleave; "(serial)" scopes become sums | owned-only counters, per-partition tagged lines (§1.4, §1.10) |
| R13 | med | A1 audit: only `eco_enable_list_chunks` needs a flag; compute-mode hoisting is unsound per partition | flag; EcoSplit requires the cap plan stamp when hoisting is On |
| R14 | med | import-miss and export-miss risks were swapped | swapped (§3) |
| R15 | low | edge kinds are OR-ed; use `kind & Call` | §2 |
| R16 | low | `__eco_lazysplit` names would collide per partition | assert no unnamed globals (§1.5) |
| R17 | low | AlwaysInliner deletes only alwaysinline bodies; copy identity holds once the chunks flag exists | noted |
| R18 | low | numbers mixed TL (44.07 s) and SPL (38.61 s); translation is 6.30 s; teardown and copy work omitted | corrected (§0) |
| R19 | low | LPT ignores import cost | measured in G5 |
| R20 | low | `finishReachability`'s oracle is an env static; per partition it would delete cross-partition definitions | explicit bypass (§1.7) |
| R21 | low | deviation from master §4.3 (internal linkage) not recorded | recorded (§1.5) |
| R22 | low | eco-boot open-world `.o` splits too; few exports; `ld -r` unchanged | covered (§1.9) |

**Verified as stated:**
- the chunks gate and `main`-only injection;
- the prepass threshold, whole-module scope and attribute strip;
- the covered-linkage rejection;
- the late externalization;
- the whole-module twins;
- no `global_ctors`, comdats, `llvm.used` or TLS definitions from MLIR;
- all statics reachable from `runEcoBackend` are thread-safe magic statics; the mutable globals are mutex-guarded;
- the SPL numbers.

# Part II: implementation specification

## U0. Files

| File | Change |
|---|---|
| `runtime/src/codegen/EcoSplit.h/.cpp` (new) | `buildPartitions` (ownership, imports, exports, clone, S6, census) and `lowerSplit` (threads, translate, worker job, join) |
| `runtime/src/codegen/EcoBackend.h` | `struct PartitionWorkerInfo`; `EcoBackendJob::partition`; `choosePartitionCountForCount`; `partitionDumpPath` |
| `runtime/src/codegen/EcoBackend.cpp` | partition-mode behaviours (U3); chunks flag; retire the lazy path (U6) |
| `runtime/src/codegen/eco-boot.cpp`, `EcoNativeDriver.cpp` | take the EcoSplit path when eligible (U4) |
| `runtime/src/codegen/CMakeLists.txt` | add `EcoSplit.cpp` |
| `design_docs/invariants.csv` | CGEN_083 |

## U1. `buildPartitions(ModuleOp src, unsigned N, const SplitOptions&) -> SplitPlan`

1. `g = symgraph::build(src)`.
2. **Ownership.**
   - Defined functions are sorted by (op count desc, name asc); LPT over N.
   - Globals with a definition go to the owner of their first referrer in module order (scan
     owners' out-edges in module order); else partition 0.
   - Declarations have no owner.
3. **Imports** (skipped when `!opts.imports`). For each P:
   - the worklist starts from the `Call`-bit targets of P's owned functions that are `$cap`
     definitions owned elsewhere;
   - pop t; add it to Imp(P); push its `Call`-bit `$cap` targets that are owned ≠ P and not yet
     in Imp(P).
4. **Exports.** For each owned function f: f is exported iff some node with a different owner
   has an edge to f, or f ∈ Imp(Q) for some Q ≠ owner(f), or some import copy in another
   partition references f.
   - Simplest exact rule: for every partition P, every symbol referenced by P's owned
     definitions or import copies that P does not own is "needed from elsewhere". The owner
     exports it if it is a function.
5. **Chunks fact:** `eco_enable_list_chunks` is a node and some edge targets it → add the flag
   `eco-list-chunks`=`1`.
6. **Clone, parallel per P** (`parallelForEach` over partitions):
   - new `ModuleOp`; copy the module attributes;
   - **declarations:** for each referenced symbol not owned by P and not imported, in module
     order, `cloneWithoutRegions`:
     - functions: linkage External; drop `visibility_`, `dso_local`, `comdat`;
     - globals: remove the value attribute (and the initializer region is not cloned); linkage
       External;
   - **definitions:** owned definitions and import copies in module order. Copies get linkage
     `AvailableExternally`;
   - **module flags:** clone every `llvm.module_flags`. If the chunks fact holds, append the flag
     (create the op if absent). Partition 0 also gets any other non-symbol top-level op.
7. **S6:** for every declaration and copy in P, its passthrough `eco-cap-*` entries must equal
   the source op's, else a hard error naming the symbol. Under `ECO_SPLIT_FAULT_DROP_COVERED=<name>`,
   the clone of `<name>` loses `eco-cap-covered` before the check (test hook).
8. **Census** (`ECO_MLIR_SPLIT_STATS=1`):
   `[mlir-split] N= defined= imports(min/avg/max)= exports= decls(sum)= build=Ts`.

Result: the N modules plus, per P, its export name list.

## U2. `lowerSplit(ModuleOp src, const EcoBackendJob &base, unsigned N, EcoBackendResult*)`

1. Register the builtin and LLVM dialect translations on the context (once).
2. `plan = buildPartitions(…)`.
3. Start a helper thread that destroys `src`'s body (`src.getBody()->clear()` after dropping
   references); the caller still owns the op.
4. Mint object paths: path 0 = `base.objectFilePath`, the others temporary (as today).
5. Start N `std::thread`s. Worker i:
   1. `tlPartitionIndex = i`;
   2. `LLVMContext`; `translateModuleToLLVMIR(*plan.mods[i], ctx)`, then free `plan.mods[i]`;
   3. rename `main` → `eco_main` (function or declaration) when `base.renameMain`;
   4. `finishReachability(m, keep, /*partition=*/true)` if the reach flag is present (sweep
      only, no oracle);
   5. TargetMachine at `base.optLevel`, or `devEmitCodeGenLevel` under dev;
   6. the job: a copy of `base` with `tm`, `objectFilePath = paths[i]`, `splitEligible = true`,
      `splitCodegen = 1`, and `partition = &info[i]` (exports, gc report out);
   7. `runEcoBackend(m, job, &r)`; record errors.
6. Join all threads, then the teardown thread.
7. `checkCrossPartitionGcLeaf(reports)`; fill `result->objectFiles` and `ownedTempFiles`.

## U3. Partition-worker behaviours in `runEcoBackend` (`job.partition != nullptr`)

- **Chunks gate:** `eco_enable_list_chunks` declared and used, **or** the module flag
  `eco-list-chunks` → emit the chunk compare. Strip the flag in the gc-free finish step (all
  modes).
- **Hoisting:**
  - plan-given verification accepts `available_externally` for the local-linkage rule;
  - census counters skip `available_externally`;
  - the 01 validate twin is skipped;
  - compute mode is an error when hoisting is On (the plan stamp is required).
- **Before the prepass:** for each export name, a function with local linkage → External +
  `Hidden`.
- **After the prepass (and at -O0):** every `available_externally` function → `deleteBody()`,
  linkage External.
- **gc-free:** `finishGcFreePlan` skips its twin; dump paths get the partition suffix.
- **After the gc-free finish:**
  - assert no unnamed globals;
  - `externalizeAllLocals(m)`;
  - hard error if any function has `available_externally` linkage (all modes);
  - after RS4GC, fill `partition->gcReport` (`collectGcLeafReport`).
- **Dumps:** `partitionDumpPath(p)` appends `.p<i>` when `tlPartitionIndex >= 0`.

## U4. Drivers

- **Eligibility, computed after the MLIR pipeline:**
  - output is EmitObjectFile;
  - `parallelOpt ∈ {Cgu, Dev}`;
  - `!rs4gcAfterOpt`;
  - `context.isMultithreadingEnabled()`;
  - `ECO_MLIR_SPLIT` is not `0`;
  - N = `choosePartitionCountForCount(definedFunctions(module), splitCodegen, splitEligible)` > 1.

  `ECO_SPLIT_MIN_FUNCS` lowers the 4,000-function threshold for tests.
- **eco-boot:** inside the MLIR scope, instead of translate + `finishReachability` +
  `runEcoBackend`, call `lowerSplit`. The keep list is `{eco_main, __eco_init_globals}` or the
  `--internalize-keep` list. The obj path (`ld -r`) and link are unchanged.
- **EcoNativeDriver (exe):** same, with `renameMain`.

## U5. Gates

1. `check` (all three validate switches; the JIT/obj paths are unchanged).
2. **G2, per-function pre-RS4GC IR:** `--dump-pre-rs4gc-ir` with `ECO_MLIR_SPLIT=0` (whole
   module) vs the new path (`.p0`…`.p23`).
   - **Normalizer:** per `define` take the body (from `{` to the closing `}`); drop the `define`
     line's linkage/visibility/attribute-group reference; erase `#N` and `!N` references.
   - **Compare:** the common functions must be identical. The new-path extras must be exported
     `$cap`s only. The old-path extras must be none.
3. **G3:** bootstrap fixed point; 9a (`--internalize-keep` object) and 9b (EcoNativeDriver).
4. **G4:** `run-aot-e2e` normal, and with `ECO_SPLIT_MIN_FUNCS=2` + `ECO_AOT_EXTRA_FLAGS=--split-codegen=4`
   (forced split on every program).
5. **G5:** loop entry: one lowering, wall, RSS, partition-load spread.
6. **G6:** self-compile runtime tax (N = 3, interleaved): a compiler lowered by the new path vs
   the old path, ≤ 3 %.
7. **G7:** determinism: two lowerings → identical ELF.
8. **G8:** S6 fault injection aborts; a TSan smoke run, if the heap-tsan build exists. Otherwise
   record it as not run.

## U6. Retirement (after G1–G7)

- Delete `emitObjectFilesSplitLazy`, the `lazySplit` job field and the `--lazy-split` option,
  and the lazy branch in `runEcoBackend`. `externalizeAllLocals` stays: it is used per
  partition.
- `emitObjectFilesSplit` (SplitModule) stays for `--parallel-opt=none`, `--rs4gc-after-opt`,
  `ECO_MLIR_SPLIT=0` and the single-threaded context.

## U7. Invariant text

**CGEN_083 (new):** with `parallelOpt ∈ {cgu, dev}` and N > 1, the program is partitioned in
MLIR (EcoSplit):
- LPT ownership on MLIR op counts; globals at their first referrer;
- `$cap` import copies as `available_externally` (the `Call`-bit closure, only when the prepass
  runs);
- exports of cross-referenced functions before the prepass;
- declarations cloned with all attributes;
- `llvm.module_flags` in every partition, plus `eco-list-chunks` for the one whole-module
  expansion gate.

EcoSplit hard-errors on any `eco-cap-*` difference between a declaration or copy and its owner
(01 S6). Each partition is translated and lowered by `runEcoBackend` in partition-worker mode on
its own thread, LLVMContext and TargetMachine. Import copies are dropped after the prepass, and no
`available_externally` function may reach RS4GC. Whole-module twins are bypassed per partition.
The lazy bitcode split is retired; `emitObjectFilesSplit` remains for the non-default modes.

## Implementation results (2026-10-02)

U0–U7 were built as specified. All gates pass.

**What was built:**
- `runtime/src/codegen/EcoSplit.{h,cpp}`: `mlirSplitPartitionCount` and `lowerMlirSplit`.
- `EcoSymbolGraph::build(…, keepUnusedAddressOf)`: declarations must cover every symbol a
  cloned body names.
- Partition-worker mode in `runEcoBackend`:
  - exports before the prepass, unconditional copy drop, late `externalizeAllLocals`;
  - the `available_externally` hard error before RS4GC;
  - the plan-given verification accepts copies;
  - the twins and oracles are bypassed;
  - `.p<i>` dump paths, `[caphoist p<i>]` lines with `import_copies=`;
  - `(sum over workers)` stats rows for RS4GC, opt, emit and the prepass.
- The chunks module flag, read by the get-tag gate and stripped before emission.
- `ECO_SPLIT_MIN_FUNCS`, `ECO_MLIR_SPLIT=0`, `ECO_MLIR_SPLIT_STATS`, and
  `ECO_SPLIT_FAULT_DROP_COVERED` (a name, or `*`).
- Both drivers wired, and CGEN_083 added.
- **Retired:** `emitObjectFilesSplitLazy`, `EcoBackendJob::lazySplit`, `--lazy-split`, the
  native driver's `lazySplit` option, and the then-unused `partitionOfName`. The ELF is
  byte-identical before and after the retirement.

**Census (self-compile):**
- N = 24 and 75,775 defined functions;
- imports 987–1,037 per partition (average 1,011);
- exports 73,631: about 93 % of call edges cross partitions, so almost every function is
  referenced from elsewhere;
- 124,216 declarations in total;
- op-count load spread 174,283–174,286;
- the chunks flag is set;
- build 0.71–0.75 s.

**Gates:**

| Gate | Result |
|---|---|
| G1 `check` (all validate switches) | 2028 / 0 |
| G2 per-function pre-RS4GC IR vs the translate-whole path | 73,602 common functions, **0 body differences after normalizing phi incoming order** (2,240 differ only in phi order: cloning reverses block use-lists and translation emits phi incomings in use-list order, which is semantically neutral); new-only = 2,262 exported `$cap` bodies whose remote copies were all inlined (dead code kept alive by the export, the known cost); old-only = 0 |
| G3 bootstrap | 4b and 8c fixed points, 9a (`--internalize-keep` object + `ld -r`) and 9b (EcoNativeDriver, `eco make`) OK. All five lowering stages took EcoSplit (9b confirmed with `ECO_MLIR_SPLIT_STATS`). Stage 7b **25.38 s** (was 44.77 s), peak RSS 7.33 GiB (was 7.53) |
| G4 `run-aot-e2e` | 900 / 902 normally, and 900 / 902 with `ECO_SPLIT_MIN_FUNCS=2 ECO_AOT_EXTRA_FLAGS=--split-codegen=4` (every program split in two). The 2 failures are the known FlagsRecordTest and PortEchoTest. The forced-split run first failed 866 tests with the front end's "CORRUPT CACHE" on re-used per-test caches (no front-end rebuild involved); moving the caches aside fixed it |
| G5 loop entry ES | **25.53 s** wall (SPL 38.61 s, −13.08 s), user 365.09 s, RSS 7,694,944 kB; partition emit Σ 156.24 s, opt Σ 127.26 s, translate Σ 22.44 s, drain 14.54 s |
| G6 runtime tax (`selfcompile.sh`, N = 3, interleaved) | EcoSplit-lowered compiler 108.54 s vs lazy-split-lowered 110.50 s (−1.8 %, inside the noise); all six self-compile outputs byte-identical |
| G7 determinism | two lowerings → identical ELF |
| G8 | S6 fault injection (`ECO_SPLIT_FAULT_DROP_COVERED='*'`) aborts with the S6 message. TSan smoke **not run**: no TSan build of the codegen exists in the tree |

**Remaining serial time** (ES banner): MLIR parse 0.74 s, the MLIR pipeline 8.16 s (with its
serial EcoToLLVM front part and tail-conversion straggler), the EcoSplit build 0.73 s, the drain
14.54 s and the link 1.10 s.

**Follow-ups, not done:**
- master §4.3 internal linkage for partition-local symbols (would re-enable intra-partition IPO;
  needs its own tax measurement);
- not exporting `$cap` bodies whose every remote copy was inlined (2,262 dead bodies);
- import-aware LPT balance;
- a TSan run.

