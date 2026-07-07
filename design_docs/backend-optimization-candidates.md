# Backend lowering pipeline — next-round optimization candidates

Date: 2026-07-07. Investigation of four axes: (1) remaining parallelism,
(2) MLIR bytecode bloat, (3) expensive-low-value passes, (4) algorithm choices.
Follows `backend-pipeline-performance.md` (222s→82s round) and
`plans/backend-serial-floor-pipelining.md` (82s→31s round, lazy split default).

## 0. Fresh baseline (measured 2026-07-07)

`eco-boot-native --lowering-stats -O 2 --parallel-opt=dev` on
`build/compiler/build-kernel/bin/eco-compiler.mlir` (12MB bytecode, 84,485 fns),
24-core box, N=24 partitions (the 16-cap drop from the sweep is in effect):

**Wall 28.77s, CPU 466%, peak RSS 4.9GB, 1.47M minor page faults.**

Serial spine (sums to ~27.3s ≈ the whole wall — the parallel section is now
almost fully hidden behind the 4.45s drain):

| Stage | Wall | Character |
|---|---|---|
| MLIR parse + verify | 0.73s | serial |
| MLIR lowering pipeline | **9.43s** | mixed (see below) |
| MLIR→LLVM translation | **5.64s** | serial, **includes LLVM verifier** |
| Internalize + GlobalDCE | 0.38s | serial |
| cheap-IPO prologue | **4.25s** | serial |
| Externalize + serialize | 1.30s | serial (N-independent, Phase 5) |
| Drain (wait for workers) | **4.45s** | parallel-bound |
| Link | 1.14s | serial |

Inside the MLIR pipeline (pass timings; nested passes overlap wall):

| Pass | Time | Anchor |
|---|---|---|
| EcoToLLVMPass | **5.31s** | Module — SERIAL |
| ArithToLLVM | 3.21s (summed) | nested LLVMFuncOp — parallel |
| SCFToControlFlow | 3.00s (summed) | nested LLVMFuncOp — parallel |
| Canonicalizer | 2.82s (summed) | nested func — parallel |
| EcoControlFlowToSCF | 1.24s | Module — SERIAL |
| ConvertControlFlowToLLVM | 0.92s | Module — SERIAL |
| EcoGCPrepare | 0.52s | Module — SERIAL |
| ReconcileUnrealizedCasts | 0.24s | Module — SERIAL |
| BFToLLVM / PAPSimplify / rest | <0.25s | — |

Worker-side (summed over 24): emit 59.1s, partition opt 20.0s, RS4GC 4.6s,
lazy extract 4.1s ⇒ ~3.7s/worker, matching the 4.45s drain. **The pipeline is
Amdahl-limited by the serial spine**; CPU 466% of 2400% confirms it.

---

## 1. Parallelism candidates

### P1. Disable LLVM-IR verification in translation ★ top quick win
`translateModuleToLLVMIR(module, llvmContext)` at `eco-boot.cpp:382` and
`EcoNativeDriver.cpp:120` uses the default `disableVerification=false`
(4th param, `mlir/Target/LLVMIR/Export.h:29`) — the produced 85k-function LLVM
module is **verified on every build**. Pass `true`, gated
`#ifndef ECO_LOWERING_VALIDATION` exactly like the MLIR-side
`pm.enableVerifier(false)` hygiene. Est. **1–2s** of the 5.64s (measure).
Risk: none in release; validation builds keep it. Effort: 2 lines.

### P2. Nest ConvertControlFlowToLLVM per-function (−0.9s serial → parallel)
`EcoPipeline.cpp:103` runs it module-anchored. It is module-level in stock MLIR
only for `cf.assert` symbol insertion — the pass audit confirmed eco emits no
`cf.assert`. Nest on `LLVM::LLVMFuncOp` like the shipped SCF/Arith subset
(serial-floor P1 SAFE trick). Same argument likely applies to
**EcoControlFlowToSCF (1.24s)** — it's ours; if its patterns are function-local,
anchor it on `func::FuncOp`. Combined est. **−1.5 to −2s** serial. Risk: low-med
(⚠ the FUSED EcoTailConversions rewrite remains PARKED with its Heisenbug —
this is the incremental nesting approach, not that).

### P3. Function-parallel EcoToLLVMPass (the big MLIR lever, B3)
5.31s module-anchored serial (`Passes/EcoToLLVM.cpp`, ~9.8k lines). Structure:
pre-scan (origFuncTypes cache) → lowerAllocGroups → applyFullConversion →
post-walks. Parallelization shape: hoist ALL module-level artifact creation
(runtime decls, string-literal globals, eval layouts — largely already cached
via symCache) into a serial prologue, then run conversion per-function in
parallel. Watch `EcoToLLVMFunc.cpp:39` (`module.lookupSymbol` per pattern).
Est. **5.31s → 1.5–2.5s**. Risk: MEDIUM-HIGH (on-demand `getOrCreate*` in
patterns must be proven pre-hoisted; conversion rewriter per-function needs its
own pattern applicator). Effort: the largest item here (1–3 weeks).

### P4. Dev-tier: cheaper worker payload → shrink the 4.45s drain
Workers cost ~3.7s each; emit (59.1s summed) dominates.
- **P4a**: dev tier currently emits with the same TargetMachine opt level as
  release. Set `CodeGenOptLevel::Less` (or enable FastISel) for
  `--parallel-opt=dev` object emission. ISel is the bulk of emit; est.
  **−1.5 to −2.5s wall** for dev builds. Risk: dev-tier binary slightly slower
  (acceptable by definition of the tier); GC statepoint lowering must be
  re-validated under FastISel (statepoints force SelectionDAG fallback —
  verify, may cap the win).
- **P4b**: dev tier `buildFunctionSimplificationPipeline(O2)` → O1
  (`EcoBackend.cpp:147-166`): partition opt 20.0s → ~12s summed, est.
  **−0.3 to −0.5s wall** + lower CPU. Risk: low.

### P5. Per-partition GlobalDCE + dedupe the double DCE
GlobalDCE currently runs twice on the exe path: in
`internalizeAndDCEForExecutable` (`EcoBackend.cpp:626`, called from drivers) and
at the end of `runCheapModuleIPO` (`EcoBackend.cpp:138`). The second is
after-IPO cleanup (legit) but could move into workers per-partition
(externalized globals stay reachable). Est. **−0.3 to −0.6s**. Risk: LOW.

### P6. Do NOT pursue (assessed, negative)
- **MLIR-level module split before translation**: needs a bespoke MLIR
  splitter + cross-partition symbol semantics; weeks of effort for ≤5.6s
  ceiling. Not worth it while P1/P3 are open.
- **Whole-module IPSCCP/GlobalOpt decomposition**: their value on monomorphized
  code needs cross-module visibility (measured in prior rounds); splitting them
  regresses the produced binary → recursive tax.
- **Link overlap with drain**: link is 1.14s; overlap buys <2%.
- **Straggler binpack by size**: drain matches mean worker time — no visible
  skew at N=24. Revisit only if a straggler shows in stats.

### P7. Memory pressure (supporting, not standalone)
4.9GB RSS / 1.47M minor faults; CPU efficiency of workers is mem-bw bound.
Destroying the MLIR module (and bytecode buffer) before the LLVM phases, and
`shouldLazyLoadMetadata=true` in workers, would cut the working set. Est.
indirect (better worker scaling). Verify MLIR module lifetime in
`eco-boot.cpp` post-translation.

---

## 2. MLIR bytecode bloat (verified empirically)

Context: backend parse is only 0.73s — bytecode size chiefly costs the
**frontend** (PhaseMlir ≈ 20.3s of `eco make`, which includes Elm-side encode)
plus attr-table churn on both sides.

### B1. `_operand_types` is dead weight in bytecode ★ verified write-only
Emitted at **99 sites across 7 Elm files** (`Ops.elm`, `Expr.elm`,
`Patterns.elm`, `Lambdas.elm`, `Intrinsics.elm`, `BytesFusion/Emit.elm`).
Its ONLY reader is the Elm textual debug printer (`Mlir/Pretty.elm:256`) —
the bytecode encoder never reads it (`IrSection.elm` just serializes op.attrs
wholesale via `dictAttrIndex`) and **no C++ backend code reads it** (grep:
only a doc mention at `Ops.td:1261`). Fix: filter it out at bytecode-encode
time (one place, `IrSection.elm`/`AttrType.elm` collection) — textual printing
keeps working. ⚠ Do NOT blanket-strip underscore attrs: `_fast_evaluator` IS
read by the backend (`EcoOps.cpp:57,63`). Payoff: smaller artifact (its dict
entries + array-of-TypeAttr table entries + per-op dict indices), faster Elm
encode, faster parse. Size estimate needs a measure-by-doing (agent's 3–5MB is
an upper-bound guess; attr dedup mitigates). Effort: trivial.

### B2. Symbol names are 16% of the artifact
64,876 identifier strings, **1.9MB of 12MB**; p50=29 chars, p99=60, max 89
(`Compiler_..._$_14331` mangling). A `--short-symbols` mode (hash-compressed
names for non-exported fns) would shrink bytecode, LLVM symtabs, object
files, stackmap name tables, and link inputs. Tradeoff: debuggability/profiling
— keep off by default, or shorten only `$_NNNN`-suffixed specializations where
the prefix repeats. Effort: medium (mangler + anything keying on names —
`partitionOfName` is name-hash based and unaffected by *consistent* renames).

### B3. Downgraded/cleared findings
- **Eco types textual encoding**: only ~118 distinct type strings in the whole
  artifact (`!eco.value` appears ONCE — dedup works). A
  `BytecodeDialectInterface` would buy ~nothing. **Skip.**
- **Locations**: all ops carry UnknownLoc; the format requires a loc index per
  op but they all collapse to one entry ⇒ ~1 varint/op. Real but small; the
  block-arg loc collection (`AttrType.elm:647`) is dedup-cheap. **Low priority.**
- **`callee`/`case_kind`/`tags` attrs**: needed and properly deduplicated.
- **Unused dialect ops**: 132 defined in `Ops.td`, only 34 emitted — zero
  artifact cost (dialect section only names what's used); maintenance-only.
  (The 3 stale RC-op test fixtures are already XFAIL'd — see jit-test-tidy.md.)

### B4. Emit-shape audit (measurement proposed)
Canonicalizer sums 2.82s over 63k runs, and the emitter may produce IR that it
immediately deletes (box/unbox pairs, one-shot joinpoints, constant
re-materialization). Measure: op-count before/after the canonicalize step; big
deltas identify emit-side waste that would shrink bytecode AND MLIR-phase time.

---

## 3. Expensive-but-low-value pass candidates

Full 31-pass inventory audited (validation gates all confirmed correctly
`#ifdef ECO_LOWERING_VALIDATION`; MLIR verifier off at `eco-boot.cpp:357`,
`EcoNativeDriver.cpp:100`). Candidates, ranked:

| # | Candidate | Cost now | Action | Risk |
|---|---|---|---|---|
| 1 | **LLVM-IR verify inside translation** (=P1) | ~1–2s? | disable in release | none |
| 2 | **Canonicalizer (EcoPipeline.cpp:76)** | 2.82s summed (parallel) | A/B: does LLVM -O2 subsume it? Removing may *grow* translation/RS4GC input though — measure both wall AND binary | low (measurable) |
| 3 | **cheap-IPO FnAttrs pair** (`EcoBackend.cpp:135-137`) | part of 4.25s | A/B: per-partition opt may re-derive locally; drop from prologue if produced binary unchanged | low (measurable) |
| 4 | **Double GlobalDCE** (=P5) | ~0.2–0.4s | merge/move per-partition | low |
| 5 | **dev-tier opt level** (=P4b) | 20s summed | O1 for dev | low |
| 6 | JoinpointNormalization+EcoControlFlowToSCF fusion | ~0.1s | fold analysis into consumer | low, tiny |

Explicit KEEP list (correctness or measured-valuable): EcoGCPrepare, RS4GC,
EcoToLLVM, RCElimination, UndefinedFunction, mem2reg/SROA/FoldExtractValue
(RS4GC prerequisites), IPSCCP+GlobalOpt (monomorphized-code IPO — prior round
verified valuable; removal = recursive tax), ReconcileUnrealizedCasts.

---

## 4. Algorithm-level findings (micro tier, batch as one cleanup PR)

No O(n²) whales remain in our code after the prior three rounds; what's left is
structural. The scan found (each <1%, aggregate maybe 0.5–1s):

| Finding | Where | Fix |
|---|---|---|
| Two consecutive full-module walks (GC strategy + shadow roots) | `EcoToLLVM.cpp:363,373` | fuse into one walk |
| Per-pattern `std::to_string` + utf8→utf16 vector + global creation in string-case lowering | `EcoToLLVMControlFlow.cpp:366-472` | cache utf16 by StringRef; format once |
| Per-op double attr probe in 4-level alloc-group loop | `EcoToLLVMHeap.cpp:1853` | collect leaders in one targeted walk |
| `StringAttr::get` per `lookupSymbol` call | `EcoToLLVMInternal.h:301-306` | StringAttr-taking overload for hot callers |
| `SmallPtrSet` rebuilt per alloc-op in group scan | `EcoGCPrepare.cpp:199-209` | hoist/incrementally maintain |

---

## 5. Ranked shortlist (what to actually explore, in order)

| Rank | Item | Est. wall (dev self-host, 28.8s base) | Effort | Risk |
|---|---|---|---|---|
| 1 | P1 translation verify off | −1 to −2s | 2 lines | none |
| 2 | P2 nest CF-to-LLVM (+EcoCFToSCF) per-fn | −1.5 to −2s | days | low-med |
| 3 | P4a dev-tier FastISel/CodeGenOpt::Less emit | −1.5 to −2.5s | days | med (statepoints) |
| 4 | B1 strip `_operand_types` from bytecode | frontend-side (PhaseMlir) + parse | trivial | none |
| 5 | P5 GlobalDCE dedupe/per-partition | −0.3 to −0.6s | 1–2 days | low |
| 6 | §3.2/3.3 Canonicalizer + FnAttrs A/B measurements | −0 to −1.5s | days (measure) | low |
| 7 | P3 function-parallel EcoToLLVM | −3 to −4s | 1–3 weeks | med-high |
| 8 | §4 micro-cleanup batch | −0.5 to −1s | days | low |
| 9 | B2 short-symbol mode | size/link/frontend | medium | med (debug) |

Ceiling if 1–6+8 all land: roughly **28.8s → ~21–23s** without touching
EcoToLLVM; adding P3 brings **~17–19s** into reach. Beyond that the floor is
translation + cheap-IPO + parse + link (~11s), i.e. the next structural step
would be attacking translation itself — previously assessed as not worth it.

## 6. Measurement protocol

As before: `eco-boot-native --lowering-stats -O 2 --parallel-opt=dev` on
`build/compiler/build-kernel/bin/eco-compiler.mlir`; validate with AOT elm-core
sweep (dev+cgu, serial, fresh eco-stuff per mode) + JIT E2E `test/test` +
self-host byte-identical functional-output check (the strongest gate).
For B1: also compare `eco make --stats` PhaseMlir and artifact size before/after.
