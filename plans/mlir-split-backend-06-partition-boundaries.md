# MLIR split backend 06: partition-boundary follow-ups to EcoSplit

**Master plan:** `plans/mlir-split-backend.md` (§4.1 ownership, §4.3 linkage).
**Parent:** `plans/mlir-split-backend-05-ecosplit.md` (implemented 2026-10-02, "Follow-ups, not
done").
**Status:** COMPLETE 2026-10-03. **B4 built and shipped.** C2 was built, measured FLAT against its acceptance gate, and reverted. A and D were not built (S6: FLAT). The spike instrumentation was removed from the tree. Results in "Implementation results" at the end.

`EB` = `runtime/src/codegen/EcoBackend.cpp`. `ES` = `runtime/src/codegen/EcoSplit.cpp`.

## 0. Goal

EcoSplit (plan 05) partitions the program in MLIR and lowers 24 partitions in parallel
(self-compile lowering 25.53 s, loop entry ES). It deliberately reproduced the old lazy split's
boundary behaviour so that codegen changed only through partition assignment. That leaves three
costs at the partition boundaries:

| # | Follow-up | Cost today | Expected value |
|---|---|---|---|
| A | Internal linkage for symbols used only inside their partition (master §4.3) | every local is externalized (`externalizeAllLocals`), so per-partition `-O2` cannot do single-caller inlining, IPSCCP-style specialization, dead-argument elimination, `fastcc` or dead-function deletion on them | runtime (codegen quality) and possibly partition opt/emit time; **unmeasured, either direction** |
| B | Skip the 2,262 dead `$cap` bodies kept alive by exports (**decided: B4**, S1) | a `$cap` owned by Q and imported elsewhere is exported before Q's prepass. When every copy and every local call was inlined, Q still keeps a dead body. G2 counted 2,262 | worker CPU (translate, RS4GC, opt, emit of dead code) and binary size |
| C | Balance partitions on the real per-worker cost (**decided: C2**, S4; the imports turned out not to be the cause) | LPT balances owned MLIR op counts only (174,283–174,286 per partition); each partition also lowers 987–1,037 import copies, uncounted | the drain's tail: the last worker sets the wall (drain 14.54 s) |
| D | Co-locate callees with their callers (master §4.1) — the common lever | 93 % of call edges cross partitions; 73,631 of 75,775 functions are exported | fewer exports (helps A), fewer imports (helps B and C) |

Each item is judged by the backend loop's rules (`benchmarks/backend-opt-loop.md`): one lowering
run per step, wall time primary. Any codegen-changing step also needs the self-compile runtime
tax gate (N = 3, interleaved, ≤ 3 %).

## 1. Facts carried over from plan 05

- **Exports:** an owned function is exported when another partition declares it or imports it
  (`ES` U1 step 4). It becomes External + hidden *before* the `$cap` prepass, so AlwaysInliner
  cannot delete it.
- **Imports:** the `Call`-bit closure into `$cap` bodies owned elsewhere, only when the prepass
  runs. Copies are `available_externally`; survivors of the prepass are turned back into
  declarations (`EB` partition steps).
- **Prepass rule** (`runCapInlinePrepass`): a `$cap` function gets `alwaysinline` when it is
  defined, has no `noinline` attribute, has at most `ECO_CAP_INLINE_MAX_INSTS` (default 64)
  **post-expansion LLVM instructions**, and, in the barriers-off / GCFREE_ONLY configurations,
  is GC-call-free. AlwaysInliner then inlines every direct call it can and deletes inlined
  *discardable* bodies (internal, private, `available_externally`) that end up unused.
- **G2 (plan 05)** compared the old whole-module path with EcoSplit:
  - every common function is identical modulo phi order;
  - new-only = 2,262 `$cap` bodies, all exported;
  - old-only = 0.

  So the 2,262 are exactly the bodies the whole-module prepass deleted and EcoSplit keeps.
- **Ownership:** LPT on MLIR op count; globals at their first referrer's owner.

## 2. Census and spikes (do these first)

All spikes run on `stats-backend-opt/p04/p2.mlir`, the plan-04 compiler's own MLIR, and change
no default output. New diagnostics sit behind `ECO_MLIR_SPLIT_STATS=2` (more detail than the
existing `=1`) or a dedicated `ECO_SPLIT_CENSUS_DIR=<dir>` that writes per-partition TSV files
(the `.p<N>` suffix mechanism already exists).

### S1. Why each of the 2,262 dead bodies survives (decides B)

**Instrument** each worker, after its prepass, to write one row per `$cap` function it holds:
- name, role (owned or import copy);
- post-expansion instruction count;
- whether it got `alwaysinline`;
- whether it was exported;
- remaining uses after AlwaysInliner, by kind: direct call, address, or none;
- for import copies: inlined everywhere in this partition, or survived and dropped back to a
  declaration.

**Join** the 24 files offline (`stats-backend-opt/spikes/s1_join.py`). For each exported
`$cap` f owned by Q, classify:

| class | meaning | consequence for B |
|---|---|---|
| **B-dead** | every importer inlined all its copies of f, and Q's own uses are gone | the body is dead (the 2,262) |
| **B-needed-remote** | some importer kept a declaration (a copy was not inlined) | Q must keep the body |
| **B-needed-local** | Q itself still has a use: an un-inlined call, an address take, or a non-`$cap` declaration reference elsewhere | Q keeps it regardless |

Then, for the B-dead set, measure how **predictable** "will be inlined everywhere" is from
facts available in MLIR *before* translation:
- **P1:** MLIR op count of f ≤ a threshold T. Find T so that op count ≤ T implies ≤ 64
  post-expansion LLVM instructions. Report the scatter of op count against post-expansion
  instruction count and the precision/recall of each candidate T.
- **P2:** f is not address-taken (no `Address` or `CallMismatch` edge into it in
  EcoSymbolGraph). Every reference is a matched-type direct call.
- **P3:** f is not self-recursive and not in a `$cap` call cycle (AlwaysInliner will not inline
  a recursive call).
- **P4:** f carries no `noinline`, and (in the barriers-off configurations only) its body is
  GC-call-free.
- **P5:** every *non-`$cap`* reference to f comes from an owned or imported body that will itself
  be inlined. In practice: f's only referrers are `$cap` callers inside the import closure.

**Outputs** of S1:
- the counts of the three classes;
- for each predictor combination: **false "dead"** predictions (the body would be needed — a
  link error if we withheld the export) and **missed** dead bodies (kept for nothing);
- the CPU those 2,262 bodies cost in the workers: post-expansion instructions, plus emitted
  object bytes (from S1's rows and a size read of each partition object's symbols, `nm --size`).

#### S1 results (2026-10-03)

**How it was run:**
- `ECO_SPLIT_CENSUS_DIR=stats-backend-opt/spikes/s1` lowering of `stats-backend-opt/p04/p2.mlir`.
- The output ELF is byte-identical to the census-free build.
- Join: `stats-backend-opt/spikes/s1_join.py`.
- Instrumentation:
  - EcoSplit writes `mlir-caps.tsv`: per `$cap`, owner, exported, importers, ops, call/address/
    non-`$cap`/total in-edges, self edge, `$cap`-call SCC size, `noinline`;
  - each worker writes `caps-{pre,post}.tsv.p<i>` (role, exported, post-expansion
    instructions, `noinline`, call/other uses), `caps-marked` and `caps-gone`.

**Ground truth over the 19,419 exported `$cap`s** (of 19,828 `$cap` functions):

| Class | Count | Detail |
|---|---|---|
| needed-remote | 16,214 | first remote holder: 9,194 declarations with an **address** use (closure creation stores the `$cap` pointer); 5,038 surviving import copies (not marked: > 64 instructions); 1,982 declarations with a direct call |
| needed-local | 943 | all through an un-inlined local call |
| **dead** | **2,262** | equal to plan 05 G2's new-only count. Together they are 49,416 post-expansion instructions (2.7 % of all owned `$cap` instructions, ~0.7 % of the module) and **225,593 bytes** in the ELF (0.68 % of sized symbols) |

**The MLIR op count is a poor stand-in for the prepass mark** (≤ 64 post-expansion LLVM
instructions). Over the exported `$cap`s:

| T (ops) | predicted | marked | not marked (wrong) | marked but missed |
|---|---|---|---|---|
| 24 | 4,767 | 4,655 | 112 | 8,877 |
| 32 | 8,865 | 8,619 | 246 | 4,913 |
| 40 | 12,390 | 11,948 | 442 | 1,584 |
| 48 | 13,601 | 13,009 | 592 | 523 |
| 64 | 14,489 | 13,469 | 1,020 | 63 |

**Predicting "dead" from MLIR facts** (FALSE_dead = an export withheld although still needed,
i.e. a link error under B1):

| Predictor | predicted | true dead | FALSE_dead | missed dead |
|---|---|---|---|---|
| P1 ops ≤ 24 | 4,767 | 1,707 | 3,060 | 555 |
| P1 ≤ 24 + P2 (no address) | 1,814 | 1,707 | **107** | 555 |
| P1 ≤ 32 + P2 | 2,086 | 1,861 | **225** | 401 |
| P1 ≤ 40 + P2 | 2,516 | 2,135 | **381** | 127 |
| P1 ≤ 48 + P2 | 2,693 | 2,223 | **470** | 39 |
| + P3 (no recursion) + P4 (no `noinline`) | identical: P3 and P4 never fire on this population | | | |
| **oracle: prepass-marked + P2 (+ P3 + P4)** | **2,262** | **2,262** | **0** | **0** |

**Verdict for B:**
- **B1 (withhold exports by an MLIR prediction): REJECTED.** Every threshold produces hundreds
  of link errors (107–470).
- **B1s (duplicate on misprediction): NOT RECOMMENDED.** At T = 48 it would duplicate 470 bodies
  to save 2,223, with no guarantee the trade is positive.
- **B2 (barrier): UNNECESSARY.** An exact rule exists without one.
- **B3 (link-time GC): UNNECESSARY.**
- **NEW: B4, owner-side export after the prepass.** The oracle is exact and needs only:
  - the prepass mark, which every partition computes **identically**: the body, expansions,
    threshold and configuration are the same in the owner and in each importer;
  - P2, a whole-program graph fact EcoSplit already has.

  **The rule:**
  1. EcoSplit passes the owner the set of its exported `$cap`s with no `Address`/`CallMismatch`
     in-edge.
  2. The owner does **not** export those before its prepass.
  3. AlwaysInliner deletes the ones it marked and fully inlined locally. Every importer marked
     and inlined its copies too, by the identity above.
  4. Right after the prepass, the owner exports whichever of them still exist.

  No prediction is involved and no synchronization. A violation (an importer failing to inline
  a marked copy) would be a loud link error; the join can turn it into a named error by
  comparing workers' surviving-and-marked copies with the owners' deletions.
- **Priority: low.** The gain is size (0.68 %) and about 0.7 % of worker instructions (≈ 0.1 s
  wall). B4 is small and exact, so it is still worth doing as a cleanup.

### S2. The cost of a synchronization point (option B2)

Option B2 makes the owners wait for the importers' verdicts:
1. every worker runs translation + expansions + hoisting + prepass;
2. it publishes "the imported `$cap` copies I could not inline";
3. a barrier;
4. each owner deletes the exported `$cap` bodies nobody needs;
5. RS4GC + opt + emit proceed.

**Measure**, with timestamps already in the stats scopes plus a per-worker timeline
(`ECO_LOWERING_TIMELINE=1`):
- each worker's time-to-prepass-end;
- the spread between the first and last worker at that point. The barrier would cost every
  worker the wait for the slowest one: that spread, minus its own lead.

**Go for B2 if** that idle cost is less than the CPU saved by deleting the dead bodies (S1)
divided by 24 workers.

### S3. Feasibility of a post-hoc cleanup (option B3)

**Option B3:** keep today's flow, but strip dead exported `$cap` bodies *after* emission, at
link time, with `--gc-sections` plus `-ffunction-sections`.

**Check:**
- whether the link already uses `--gc-sections`; read `linkExecutable`;
- whether the objects carry per-function sections;
- whether the `.llvm_stackmaps` section or the GC's stackmap parser prevents section GC.
  Stackmaps reference function addresses, so dead functions would be kept by their stackmap
  records unless the stackmap section is handled.

This option saves only binary size, not worker CPU. It is the fallback if neither B1 nor B2 is
safe or worth it.

### S4. Per-worker load (decides C)

**Instrument** `lowerMlirSplit` to record, per worker:
- wall time and CPU time;
- owned op count;
- imported op count;
- post-expansion instruction count;
- time per phase: translate, pre-RS4GC, RS4GC, opt, emit.

**Report:**
- the finish-time spread: slowest − fastest, and slowest − median;
- the correlation of finish time with:
  - (a) owned ops;
  - (b) owned + imported ops;
  - (c) post-expansion instructions.

**Go for C if** the slowest − median gap is ≥ 0.5 s and (b) or (c) predicts it clearly better
than (a).

#### S4 results (2026-10-03)

**How it was run:**
- `ECO_SPLIT_WORKER_STATS=<tsv>` (new, diagnostic): per worker, owned/imported ops and
  functions, instructions at RS4GC entry, start/translated/end offsets from the split, thread
  CPU, and the pre-RS4GC / RS4GC / opt / emit times.
- 3 lowerings of `stats-backend-opt/p04/p2.mlir` (walls 25.19 / 25.52 / 25.55 s), with the
  output ELF unchanged.
- Analysis: `stats-backend-opt/spikes/s4_analyze.py`; raw files in `stats-backend-opt/spikes/s4/`.

**Per-run findings:**

| run | finish min / median / max (s) | slowest − median | slowest − fastest | ideal = Σ CPU / 24 | corr(duration, owned ops) | corr(duration, owned + import ops) | corr(duration, instructions) |
|---|---|---|---|---|---|---|---|
| r1 | 13.28 / 13.93 / 14.42 | 0.48 | 1.13 | 13.59 | −0.32 | +0.07 | **+0.56** |
| r2 | 13.37 / 14.03 / 14.62 | 0.59 | 1.25 | 13.67 | −0.31 | −0.11 | **+0.65** |
| r3 | 13.21 / 13.97 / 14.53 | 0.56 | 1.32 | 13.60 | −0.15 | −0.23 | **+0.74** |

- **The slowest workers are the same every run:** p14, p12, p13. They are the partitions with
  the most post-expansion instructions (296–298k against a 274k minimum; spread 8.4 %).
  Owned op counts are identical by construction (174,508–174,511), and import op counts vary
  (82,745–89,426) **without** predicting duration.
- **A worker:** translate about 1.1 s (max), pre-RS4GC 0.50 s, RS4GC 0.47 s, opt 5.3 s,
  emit 6.5 s (medians). Thread CPU ≈ wall per worker: the workers are fully CPU-bound, with no
  contention signature.
- **Ceiling for C:** perfect balance ends the drain at Σ CPU / 24 ≈ 13.6 s, against 14.4–14.6 s
  today, so **≤ ~0.9 s** (≈ 3.5 % of wall). A realistic cost model might recover 0.4–0.7 s.

**Over-partitioning (a quick extra arm, C4), single runs:**

| N | wall | drain | imports per partition | Σ translate |
|---|---|---|---|---|
| 24 (default) | 25.2–25.6 s | 14.4–14.6 s | ~1,011 | 23.2 s |
| 32 | 26.98 s | 15.98 s | ~770 | 29.9 s |
| 36 | 25.28 s | 14.41 s | ~697 | 34.4 s |

The workers are one thread per partition, so N > 24 oversubscribes the cores. The total
per-partition overhead also grows: more declarations and exports, a larger Σ translate. **C4 is
rejected** without a worker pool; a pool is not worth it at this ceiling.

**Verdict for C:**
- **GO, but low priority.** The go criterion is met, marginally: slowest − median 0.48–0.59 s
  (≥ 0.5 s in 2 of 3 runs), and post-expansion instructions predict duration (+0.56 to +0.74)
  where owned and owned+import ops do not.
- **Method:** C2, balance on a **predicted post-expansion instruction count** instead of the MLIR
  op count. It needs a calibration first: **S4b**, a per-function census of MLIR op-kind
  histogram against post-expansion LLVM instructions (one more diagnostic row type), fitted
  offline to a per-op-kind weight table that EcoSplit's LPT then uses.
- C1 (adding import cost) is **not** supported by the data: imports do not explain the spread.
- C3 (rely on D first) stays a valid ordering choice: D changes ownership anyway.

### S5. Locality census (decides A and D)

From EcoSymbolGraph on `p2.mlir`, for today's ownership and for candidate co-location policies
(D1–D3 below), count:
- functions referenced **only** from their own partition (internal-linkage candidates for A),
  split by family: specs, `$cap`, `$clo`, wrappers, `$sat`;
- cross-partition call edges;
- exports;
- imports per partition;
- the op-count balance.

**Candidate policies:**
- **D1:** after LPT, move each function with exactly one caller (by `Call` edges) into its
  caller's partition. Iterate to a fixpoint, bounded by a balance cap (e.g. no partition
  > 1.05 × mean).
- **D2:** group each `$cap` with its most frequent caller.
- **D3:** cluster by strongly connected components plus single-caller chains before LPT, and
  assign whole clusters.

**Go for A** if today's ownership already gives ≥ 10 % internal-linkage candidates *by
instruction weight*, or if D1–D3 raise it there without breaking balance. Otherwise A waits
for D.

#### S5 results (2026-10-03)

**How it was run:**
- `ECO_SPLIT_CENSUS_DIR=stats-backend-opt/spikes/s5` lowering of `p2.mlir` (output ELF
  unchanged). EcoSplit dumped its graph: 128,451 nodes, 354,097 edges, op costs and today's
  owners.
- Evaluator: `stats-backend-opt/spikes/s5_policies.py`, about 3 s. It reproduces EcoSplit's
  import, export and declaration rules for any ownership.
- **Validation:** today's ownership gives **73,695 exports, equal to EcoSplit's own census**.
- "Internal" = a defined function no other partition references (owned code or import copies),
  not a root: an internal-linkage candidate for A.
- Balance cap for moves: 1.05 × mean partition ops.

| Policy | Exports | Internal candidates (share of ops) | Cross-partition calls | Imports avg / max | Load max / mean |
|---|---|---|---|---|---|
| today (EcoSplit LPT) | 73,695 | 2,175 (**1.7 %**) | 93.2 % | 1,015 / 1,048 | 1.000 |
| D1 single-caller follows caller (25,045 moves) | 61,976 | 13,894 (30.7 %) | 76.1 % | 990 / 1,010 | 1.050 |
| D2 `$cap` to its main caller's partition (7,537 moves, 2,290 refused by the cap) | 73,163 | 2,707 (2.7 %) | 83.8 % | **719** / 991 | 1.050 |
| D1 then D2 | 61,935 | 13,935 (30.8 %) | 69.8 % | 748 / 990 | 1.050 |
| **D3 cluster LPT** (single-caller chains + Call SCCs; 61,253 clusters, largest 0.35 × a mean partition) | 61,703 | 14,167 (**35.4 %**) | 75.0 % | 994 / 1,030 | **1.000** |
| D3 then D2 | 61,673 | 14,197 (35.5 %) | **68.8 %** | 744 / 1,011 | 1.050 |

**Internal candidates by family:**
- **today:** `$sat` 1,057, `$cap` 409, specs 385, wrappers 284, other 40;
- **D3:** specs 10,694, other 1,222, `$sat` 1,027, `$cap` 937, wrappers 287.

D3's gain is almost all **specs that are single-caller helpers**, now held with their caller.

**Verdict for A and D:**
- **A alone: NO-GO.** Today only 1.7 % of ops are internal candidates, far below the 10 %
  threshold. 93 % of call edges cross partitions, so internal linkage has almost nothing to act
  on.
- **D: GO with D3** (cluster LPT):
  - 35.4 % of ops become internal candidates, and 12k fewer exports;
  - cross-partition calls drop from 93.2 % to 75.0 %;
  - the op-count balance stays **perfect** (1.000), because LPT over whole clusters still has
    61k units and the largest cluster is a third of a partition.

  D1 (moving functions after LPT) reaches almost the same locality but pushes partitions to
  the cap.
- **D2 (`$cap` to its main caller):** a secondary refinement. It cuts import copies by
  ~25–30 %, but costs balance (cap reached). S4 showed balance, not imports, sets the drain.
  So D2 is not taken unless a D3 step measurement shows import-copy CPU matters.
- **A becomes worth measuring only on top of D3 (A2).** S6 runs its prototype against D3
  ownership.

**Caveats:**
- The balance figures are in **op counts**, which S4 showed are not the true worker cost (C2).
  D3's real balance must be measured, and C2's calibrated cost should be the LPT cost for D3's
  clusters.
- Every D variant changes codegen through ownership, so the tax gate applies.
- Locality alone does not change the generated code under today's late `externalizeAllLocals`.
  Its value is realised by A2.

### S6. A first runtime sample for A (cheap, before building A)

**Prototype A** behind an env (`ECO_SPLIT_INTERNAL_LOCAL=1`): externalize only exported
functions and cross-referenced globals; keep the rest at its MLIR linkage.

**Run:**
- one lowering, recording opt/emit time;
- one self-compile runtime comparison (N = 3, against today's EcoSplit).

**Go for A** if runtime improves or is flat with lower worker CPU. **No-go** if runtime
regresses beyond noise.

#### S6 results (2026-10-03)

**Prototypes** (env-gated diagnostics; the default output is byte-identical to the pre-S6 ELF):
- `ECO_SPLIT_OWNERSHIP=d3`: EcoSplit's LPT runs over D3 clusters (single-caller chains + Call
  SCCs), in `ES` `buildPartitions`.
- `ECO_SPLIT_INTERNAL_LOCAL=1` (A): the partition worker externalizes only its export list
  (functions, plus now the globals another partition declares) instead of `externalizeAllLocals`.

**Lowering** (`p2.mlir`, single runs):

| Arm | Wall | Exports (incl. globals) | Imports avg | Partition opt Σ | Partition emit Σ | Drain |
|---|---|---|---|---|---|---|
| base (today's EcoSplit) | 25.2–25.6 s (S4) | 73,695 functions | 1,015 | ~127 s | ~155 s | 14.4–14.6 s |
| D3 | 25.58 s | 66,540 | 994 | 125.9 s | 158.1 s | 14.78 s |
| D3 + A2 | 25.77 s | 66,540 | 994 | 127.3 s | 156.1 s | 14.93 s |

**Binaries:**

| Arm | Size (B) | Defined text symbols |
|---|---|---|
| base | 92,156,176 | 77,924 |
| D3 | 92,391,824 (+0.26 %) | 77,891 |
| D3 + A2 | 91,807,984 (**−0.38 %**) | **75,419 (−2,472)** |

A2 does change codegen as intended: per-partition `-O2` inlines and deletes about 2,500
internal single-caller helpers.

**Runtime** (`selfcompile.sh`, interleaved, N = 3):

| Arm | r1 | r2 | r3 | Median | RSS |
|---|---|---|---|---|---|
| base | 108.04 | 106.08 | 107.09 | **107.09** | 8.70 GB |
| D3 | 107.51 | 107.74 | 108.19 | 107.74 | 8.69 GB |
| D3 + A2 | 108.32 | 107.06 | 107.55 | 107.55 | 8.70 GB |

All nine self-compile outputs are byte-identical to `p2.mlir`.

**Verdict for A and D: FLAT on every measure that matters.**
- **Runtime:** D3 +0.6 %, D3 + A2 +0.4 %, both inside the noise (overlapping ranges). The 2,472
  extra inlined helpers buy nothing measurable at runtime.
- **Lowering:** flat (25.6–25.8 s against 25.2–25.6 s). Worker opt/emit CPU is unchanged.
- **The only gain is binary size:** −0.38 % for D3 + A2.

**Decision:**
- **A2 and D3 are NOT built** as defaults: codegen-changing steps with no measured benefit beyond
  0.4 % size.
- The two env prototypes stay as diagnostics, so the question can be re-asked cheaply after
  future front-end or codegen changes. Re-measure if the cross-partition call share or the
  inliner's behaviour changes materially.
- **D2** (fewer imports) is not taken either: S4 showed imports do not drive the drain.
- **Consequence for C:** C2's calibrated cost applies to today's per-function LPT. D3 is no
  longer the planned ownership.

## 3. Options per item, to be decided by the spikes

### B: dead `$cap` bodies — DECIDED by S1: **B4**

| Option | Mechanism | Verdict (S1, 2026-10-03) |
|---|---|---|
| B1 predict | EcoSplit withholds the export when an MLIR predictor says "inlined everywhere" | **rejected**: 107–470 FALSE_dead (each a link error) at every op-count threshold, even with the no-address filter |
| B1s safe-predict | B1, plus an importer keeps an un-inlined copy as its own internal definition | **not recommended**: at T = 48, 470 duplicated bodies to save 2,223 |
| B2 barrier | owners wait for the importers' "not inlined" lists | **unnecessary**: an exact rule exists without synchronization (S2 not needed for B) |
| B3 link-time GC | `--gc-sections` | **unnecessary** (S3 not needed for B) |
| **B4 owner-side export after the prepass** | EcoSplit passes each owner the set of its exported `$cap`s with **no `Address`/`CallMismatch` in-edge**. The owner exports those only **after** its prepass, and only the ones still defined. AlwaysInliner deletes the marked and locally fully inlined ones; every importer marked and inlined its copies too, since the prepass mark is computed identically on identical bodies | **chosen**: S1's oracle shows it is exact (2,262 / 2,262, 0 false). A violation would be a loud link error; the join adds a named check |

**B4 specification:**
1. **EcoSplit:** `exports[P]` splits into `exportsEarly` (address-taken, or a non-`$cap`
   function — exported before the prepass as today) and `exportsLate` (non-address-taken `$cap`).
2. **Worker:**
   - before the prepass, export `exportsEarly` only;
   - after the prepass and the copy drop, export each `exportsLate` function that still exists;
   - report the names of `exportsLate` functions that the prepass deleted (`deletedLate`), and
     the names of surviving import copies that were **marked** (`markedSurvivors`; expected
     empty).
3. **Join:** if any `markedSurvivors` name is in some owner's `deletedLate` → named hard error
   ("importer kept a marked copy of a deleted `$cap` body").
4. **Gates:**
   - G2-style comparison: new-only = 0 (all 2,262 gone);
   - forced-split AOT;
   - bootstrap;
   - determinism;
   - lowering wall: expected flat, about −0.1 s.

### C: load balance — DECIDED by S4: **C2** (low priority)

| Option | Verdict (S4, 2026-10-03) |
|---|---|
| C1 add import cost to the LPT load | **not supported**: import ops do not correlate with worker duration (−0.23 … +0.07) |
| **C2 better per-function cost** | **chosen**: post-expansion instructions predict duration (+0.56 … +0.74); needs the S4b calibration census (MLIR op-kind histogram → LLVM instructions), then a weight table in EcoSplit's LPT |
| C3 rely on D to shrink imports | an ordering option; D changes ownership anyway, so C2 is calibrated against D's ownership if D lands first |
| C4 over-partition (N > cores) | **rejected**: N = 32 is 1.5 s slower, N = 36 flat; per-partition overhead grows and the workers oversubscribe |

**Expected value:** ≤ 0.9 s ceiling, about 0.4–0.7 s realistic.
**Gates:** lowering wall (primary, N = 3 because the gain is near noise), determinism, and
the usual correctness suite (ownership changes codegen, so the tax gate applies too).

### A: internal linkage — DECIDED by S5 + S6: **not built** (A2 on D3 is FLAT at runtime, −0.38 % size only)

- **A1 alone (today's ownership): NO-GO.** Only 1.7 % of ops are internal candidates.
- **A2 = A1 + D3 ownership:** 35.4 % of ops are internal candidates. Worth the S6 runtime
  sample.
  - **Mechanism:** externalize only exported functions and cross-referenced globals; everything
    else keeps its MLIR linkage, so per-partition `-O2` sees internal helpers.
  - **Interaction with B4:** an owner's un-exported `$cap` stays internal, and AlwaysInliner
    deletes it when dead, exactly as in the whole-module path.

### D: ownership — S5 chose D3; S6 measured it FLAT: **not built** (kept as the `ECO_SPLIT_OWNERSHIP=d3` diagnostic)

- **Clusters:** union every function with its single caller (a single distinct referrer, a
  `Call` edge, no address use, not a root), and union the members of each `Call`-graph SCC.
  Then LPT over whole clusters: cost descending, then smallest member name; deterministic.
- The cluster cost uses C2's calibrated per-function cost once S4b exists; until then, op count.
- **D2 is held in reserve:** it reduces imports but costs balance.
- **Gates:**
  - lowering wall (N = 3);
  - S4-style finish spread;
  - tax ≤ 3 %;
  - G2-style per-function IR identity (bodies unchanged; only the assignment moves);
  - bootstrap;
  - AOT normal + forced split.

## 4. Steps

1. S1–S6 census and spikes. Record the results in this plan. Decide B, C, A and D.
   S1 is done (B → B4). S2 and S3 are no longer needed for B. S4 is done (C → C2, after an
   S4b calibration census). S5 is done (D → D3; A only as A2 on D3). S6 is done: D3 and
   A2 are FLAT, so neither is built. **Remaining work: B4, then S4b + C2.**
2. **D: not built.** S6 measured D3 (and D3 + A2) FLAT at runtime and in lowering; it stays the
   `ECO_SPLIT_OWNERSHIP=d3` diagnostic.
3. **B: B4** (decided by S1; specification in §3).
   - Gates: G2 shows new-only = 0, bootstrap, AOT normal + forced split, determinism, lowering
     wall.
4. **C: C2** (decided by S4; low priority). First S4b, the calibration census.
   - Gates: lowering wall (primary, N = 3), determinism, tax.
5. **A: not built.** S6 showed A2 on D3 FLAT at runtime (−0.38 % size only); it stays the
   `ECO_SPLIT_INTERNAL_LOCAL=1` diagnostic.
   - Gates: tax ≤ 3 % (or better), bootstrap, AOT normal + forced split, lowering wall.

Each step is a loop entry in `benchmarks/backend-opt-loop.md` against the then-best.

## 4a. Implementation specification (2026-10-03)

The spikes leave two items to build: **B4**, then **C2** (with its S4b calibration census
first). The spike instrumentation was reverted from the tree. S4b re-adds only what it needs,
temporarily, and removes it once the weights are fitted.

### B4: late export of the dead-able `$cap` bodies

1. **EcoSplit (`buildPartitions`).**
   - Split each owner's export list into `exports` (early: as today) and `exportsLate`.
   - `exportsLate` holds an owned **`$cap`** function with no `Address` or `CallMismatch`
     in-edge (graph edges plus `extraTakes`) that another partition imports or declares.
   - Everything else that is exported stays in `exports`.
2. **`PartitionWorkerInfo`:** add `exportsLate` (in), plus `deletedLate` and `markedSurvivors`
   (out).
3. **Worker (`runEcoBackend`, partition mode):**
   - before the prepass, export `exports` only (unchanged code);
   - `runCapInlinePrepass(m, &marked)` reports the names it marked `alwaysinline`;
   - right after the prepass, before the copy drop:
     - every `available_externally` copy that still exists and is in `marked` goes to
       `markedSurvivors`;
     - every `exportsLate` name: if a definition still exists, make it External + hidden;
       otherwise record it in `deletedLate`.
4. **Join (`lowerMlirSplit`):** a name in any worker's `markedSurvivors` that is also in any
   owner's `deletedLate` → hard error naming it (an importer kept a marked copy of a deleted
   body). Otherwise it would surface later as an undefined symbol at link.
5. **Gates:**
   - G2 comparison with the translate-whole path: **new-only = 0** (was 2,262), body
     differences 0 modulo phi order;
   - determinism;
   - `check`;
   - AOT normal + forced split;
   - bootstrap;
   - lowering wall: expected flat, about −0.1 s.

### S4b + C2: balance on a calibrated cost

1. **S4b census** (temporary instrumentation):
   - EcoSplit writes per defined function its op count by op name;
   - each worker writes per owned function its instruction count at RS4GC entry (after the
     prepass inlined its `$cap` callees);
   - also the per-worker wall times for the baseline (S4 method).
2. **Fit offline** (`stats-backend-opt/spikes/s4b_fit.py`): a non-negative per-op-name weight
   table plus a weight on "op count of directly called `$cap` callees" (the inlined bodies
   grow the caller). Judge it by the correlation of predicted partition cost with:
   - the measured partition instruction count;
   - the worker duration.
3. **C2:** EcoSplit's LPT uses `cost(f) = Σ_k w_k · count_k(f) + w_cap · Σ ops(directly called
   inlinable $cap)`. The weights are a compiled-in table (`ES`), with op count as the fallback
   for unknown op names.
4. **Gates:**
   - lowering wall, N = 3 interleaved against the B4 tree: accept if the median improves
     beyond noise (or is FLAT with a smaller finish spread);
   - finish spread;
   - runtime tax N = 3 (ownership changes codegen);
   - determinism, `check`, AOT normal + forced split, bootstrap.

## 5. Gates common to all steps

- `check` with the validate switches.
- `run-aot-e2e` normal **and** forced split (`ECO_SPLIT_MIN_FUNCS=2
  ECO_AOT_EXTRA_FLAGS=--split-codegen=4`). Move `build/test/aot-e2e/*/eco-stuff` aside before
  each run (the front end's CORRUPT CACHE on re-used caches).
- Bootstrap: 4b and 8c fixed points; 9a and 9b.
- Determinism: two lowerings give an identical ELF.
- The plan 05 S6 check stays on, and its fault-injection hook still fires.

## 6. Risks

| Risk | Item | Mitigation |
|---|---|---|
| Withheld export → link error | B1 | zero false predictions in S1 on the self-compile and the forced-split AOT corpus; or B1s |
| Duplicated `$cap` bodies change behaviour | B1s | function identity is not observable for direct calls; address-taken `$cap`s are excluded by P2 |
| Internal linkage changes codegen and regresses runtime | A | S6 sample first; tax gate |
| Ownership changes destabilize balance | D, C | balance cap; S4/S5 measured before and after |
| Barrier idles workers | B2 | S2 decides |
| Stackmaps keep dead functions alive at link | B3 | S3 checks first |
| Census instrumentation perturbs timings | all | timing spikes run without the TSV census; the census runs separately |

## 7. Open questions

1. Does AlwaysInliner's result depend on the order in which partitions present `$cap` bodies
   (plan 01 §4.4)? G2 showed identical bodies, but a B1 owner-side deletion could expose
   order-dependence — S1 records it.
2. Is a `$cap` ever referenced by a non-`$cap`, non-call use from another partition (closure
   creation stores the address)? P2 classifies it; such functions must stay exported.
3. Would A's internal linkage let per-partition `-O2` inline across what are now
   `available_externally` boundaries? No: copies are dropped before RS4GC, so A affects only
   owned bodies.

## Implementation results (2026-10-03)

**B4: built, kept.**
- **EcoSplit:** owned exported `$cap`s with no `Address`/`CallMismatch` in-edge go to
  `exportsLate`.
- **Worker:** exports them after the prepass if they survived. It records `deletedLate` and the
  marked import copies that survived (`markedSurvivors`).
- **Join:** turns a marked survivor of a deleted body into a named error.
- `runCapInlinePrepass` reports the functions it marks.

| Check | Result |
|---|---|
| Defined functions in the self-compile ELF | 77,924 → **75,662** (exactly −2,262, S1's dead set) |
| Binary size | 92,156,176 → 91,453,192 B (**−0.76 %**; the dead bodies also carried stackmap and unwind data) |
| G2 vs the translate-whole path | **73,602 = 73,602 functions, 0 body differences** (modulo phi order), new-only **0** (was 2,262) |
| Determinism | two lowerings byte-identical |
| Lowering wall | flat (25.18–25.41 s, 3 runs) |
| B4 join error | never fired (no marked import copy survived anywhere) |

**S4b + C2: built, measured, reverted.**
- **S4b census** (temporary instrumentation, removed): per-function MLIR op histograms against
  instruction counts at RS4GC entry, over 3 runs. Fit: `stats-backend-opt/spikes/s4b_fit.py`
  (pure Python NNLS, 30 op kinds). Data: `stats-backend-opt/spikes/s4b/` (the fitted table is
  `weights.tsv`).
  - per-function correlation with the true instruction count: op count 0.962, model **0.992**;
  - partition instruction spread under LPT: op count **8.5 %**, model **2.1 %**, oracle 0 %;
  - worker duration against instruction load: corr 0.70;
  - 15 op kinds gave 2.2 %; 50 overfit (3.7 %).
- **C2** (LPT on the fitted cost) against B4, lowering of `p2.mlir`, interleaved:

  | Arm | Walls (s) | Median | Drain (s) | Finish slowest − median / slowest − fastest (2 timeline runs) |
  |---|---|---|---|---|
  | B4 | 25.41 / 25.18 / 25.19 | 25.19 | 14.30–14.35 | 0.78 / 1.54, 0.50 / 1.32 |
  | C2 | 25.23 / 25.09 / 25.27 | 25.23 | 14.21–14.30 | 0.58 / 1.71, 0.50 / 1.52 |

- **Verdict: FLAT and no smaller spread**, so it fails the acceptance gate and is **reverted**:
  the plain op count stays the LPT cost. Balancing instructions does not move the tail. The
  remaining 0.5–0.8 s finish spread behaves like run-to-run noise rather than a load
  imbalance. The weight table and the fit stay on disk for a later re-check.
- **Generality caveat** (for any re-check): the weights were fitted **and evaluated on the
  self-compile only** (in-sample, no held-out set).
  - Several are proxies, not per-op costs: `llvm.xor` = 30 instructions is a correlate of some
    larger construct in this program's code mix.
  - K = 50 doing worse than K = 30 is a sign of overfitting.
  - The op-to-instruction expansion is a backend property and partly general, but the fitted
    table is tuned to the self-compile.
  - Only programs ≥ 4,000 functions split at all, so in practice the self-compile is the
    workload anyway.
  - A re-check should derive the cost from the backend's own expansion rules (marker kinds ×
    expansion sizes, plus post-expansion `$cap` sizes) and validate it on held-out functions or a
    second large program, instead of a regression fit.

**A and D: not built** (S5 + S6). D3 and D3 + A2 are FLAT at runtime and in lowering; the only
gain is −0.38 % size.

**Net effect of plan 06 on the default pipeline:** B4 only. 2,262 dead `$cap` bodies are no
longer emitted (−0.76 % binary), function bodies are identical to the whole-module path, and
lowering time is flat.

**Gates on the final tree (B4):**

| Gate | Result |
|---|---|
| `check` (all validate switches) | 2028 passed / 0 failed |
| `run-aot-e2e` | 900 / 902 (the known FlagsRecordTest and PortEchoTest) |
| `run-aot-e2e` forced split (`ECO_SPLIT_MIN_FUNCS=2`, `--split-codegen=4`) | 900 / 902 (same two) |
| Bootstrap | 8c fixed point, 9a and 9b OK; Stage 7b 25.67 s |
| Determinism | identical ELF across two lowerings |
| Loop entry B4X | 25.59 s wall (ES 25.53 s): FLAT, kept because it deletes work; user CPU 361.69 s (ES 365.09 s); partition emit Σ 154.09 s (ES 156.24 s) |

