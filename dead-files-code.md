# Dead files and code

These were found while writing the program theory (`THEORY.md`, `design_docs/theory/`). Each item is something nothing builds, calls, reads or reaches, or a stray file in the tree. Items 1 to 29 are in `icm-agents/workspaces/program-theory-writer/theory/review/source-drift.md`, section 6, which has the evidence. The rest were found in the later investigations of closures, value representation and runtime data structures.

The status says how sure the finding is:
- **Verified**: confirmed by reading the code, with the callers or readers searched.
- **From notes**: reported by an investigation and not re-checked.

None of these have been removed. Before deleting anything, check the last column, because a few items are kept on purpose.

## Stray files

| File | What it is | Status | Suggested action |
|---|---|---|---|
| `runtime/src/codegen/EcoBackend.cpp.orig` | A tracked, 3,791-line stale backup of `EcoBackend.cpp`. Nothing builds it. | Verified | Delete |
| `compilerdiff.txt` | A saved `git diff` of `AST/Monomorphized.elm`. | Verified | Delete |
| `compiler/recomment-bugs.txt` | A bug list that marks itself as unverified. Its entries were never checked. | From notes | Triage, then delete |
| `compiler/lib/guida.*.js`, `index.js`, `index.d.ts` | Guida npm bundles that nothing in the build references. | From notes | Delete |
| `compiler/scripts/build-self.sh`, `build-verify.sh` | Scripts CMake does not use. They have drifted from the CMake bootstrap recipes. | From notes | Delete |
| `elm-io-lib/`, `elm-io-ports-example/` | Packages that do IO through Elm ports. The build never refers to them. | From notes | Delete, or move out of the tree |
| `design_docs/guida-io-ops.csv` | The older inventory for the two packages above. | From notes | Delete with them |
| `elm-cov-file.csv` | A coverage file the build does not use. | From notes | Delete |
| `test/bf-codegen/run_tests.sh` | An old grep-based runner. The byte-fusion suite runs through `test/main.cpp`. | From notes | Delete |
| `test/codegen/run_tests.sh` | A deprecated stub that only forwards to the real runner. Its header cites a missing document. | From notes | Delete |
| `design_docs/escape-analysis.md`, `escape-analysis-status.md` | Designs for passes that were deleted. | Verified | Delete, or mark as a postmortem |

## Code with no callers

| Code | What it is | Status | Suggested action |
|---|---|---|---|
| `runtime/src/codegen/Passes.h` | Nine declarations with no definition: `createConstructLoweringPass`, `createControlFlowLoweringPass`, `createHeapOpsToLLVMPass`, `createConstantToLLVMPass`, `createCallLoweringPass`, `createStringLiteralLoweringPass`, and three `populate*Patterns`. Only a commented-out line refers to them. | Verified | Delete |
| `Backend.backend`, `Mlir/Bytecode/Encode.encodeModule` (compiler) | The whole-module MLIR emitters. The streaming bytecode path replaced them. | Verified | Delete |
| `Compiler/Pipeline/Steps.toGlobalOpt` | Its docs call it "the whole pipeline", but nothing calls it. | Verified | Delete |
| `eco_native_lower_and_link_bytes` (`EcoNativeAPI.h`) | An in-memory hand-off that exists but is unused. `eco make` writes a temporary bytecode file and calls `lowerAndLink`. | Verified | Delete, or use it |
| `eco_apply_segmentation_unknown` (`RuntimeExports.cpp`) | A runtime entry point that is declared, implemented and registered in the JIT symbol table and the backend's list. No lowering emits a call to it; both generic call kinds call `eco_apply_closure_eval`. CGEN_060 still names it. | Verified | Delete, and fix CGEN_060 |
| `scheduleCompaction` (allocator) | Compaction exists, but only tests in `test/allocator/` call it. | Verified | Keep for tests or delete; fix the docs that call it a manual trigger |
| `elm_bytebuffer_with_data` (`ElmBytesRuntime`) | A buffer accessor that stays safe across a collection. Only a unit test calls it, though the runtime's own header recommends it for safe access. | Verified | Use it to fix the fused-bytes GC hazard (bug SD-22), or delete it |
| `$clo` closure functions (MLIR generation) | Generated for every capturing closure, only because `eco.papCreate` names one and the verifier requires it to exist. Nothing calls them: evaluators, descriptors, the closure-call simplifier and the capture checker all use `$cap`. Executables drop them, but JIT runs, shared libraries and unfinalized object files keep them as dead code. | Verified | Stop generating them, and relax the verifier's symbol requirement |

## Data written or parsed but never read

| Code | What it is | Status | Suggested action |
|---|---|---|---|
| Root operands added by `EcoGCPrepare` | Live-value sets attached to each allocation and to each call that might collect. They are discarded at lowering; LLVM's statepoint rewriting computes the real roots. | Verified | Delete them, keeping the pass's grouping and fence roles |
| `eco.alloc_size_bytes` attribute | Nothing reads it. | Verified | Delete |
| `_dispatch_mode` on `papExtend` | Declared in `Ops.td` and read by `EcoPAPSimplify`, but nothing sets it. CGEN_CLOSURE_005, 007 and 008 still describe it. | Verified | Delete, and retire those invariant rows |
| `_operand_types`, `_call_kind` | Attributes that are not declared on the operations they are attached to. | Verified | Declare them, or drop them |
| `mark_work_ratio` (heap config) | Parsed and validated, but read by nothing. Its comment says it paces marking. | Verified | Delete the key and its comment |
| `Context.oracleFacts` | Installed by `Backend.deriveOracleFacts`, but nothing reads it. Its docs say it feeds code generation. | Verified | Delete, or wire it in |
| `EnforceBoundaries` exemption for `Compiler/Type/SolverSnapshot.elm` | An exemption that no longer matches any code. | Verified | Delete |

## Unreachable paths

| Code | What it is | Status | Suggested action |
|---|---|---|---|
| `emitClosureCall`'s `_closure_kind` branch (`EcoToLLVMClosures.cpp`) | Taken only when a call carries `_closure_kind`, but the compiler puts that attribute only on closure creation (`Expr.elm`). If it were reached, it would call the evaluator descriptor's address as if it were code. A comment beside it says "NOT dead". | Verified | Delete the branch, and retire `_closure_kind` on calls |
| `Types.elm` cases for a `number` type variable | `i64` at the ABI, boxed in the heap. They can't be reached: the prune step closes every `number` variable to Int and fails if one survives. | Verified | Delete, or replace with a crash |
| Rebalance branch in `maybeFlattenOrRebalance` (`StringOps.cpp`) | An empty `// TODO: rebalance` branch. It fires only for structural flattening, and the only caller, `ensureFlat`, asks for random access. | Verified | Delete, or implement it and add a caller |
| The six reference-counting operations (eco dialect) | Declared in the dialect, but nothing emits them. `RCElimination` reports each one as an error, and `test/codegen/reset_noop.mlir` is XFAIL. | Verified | Delete the operations, the pass and the fixture, or keep them deliberately |
| CGEN_062 (invariant) | No code cites it. One fixture tests the rule under its old number, CGEN_029. | Verified | Re-cite it in the fixture |

## Present on purpose, worth reviewing

| Code | What it is | Status | Suggested action |
|---|---|---|---|
| `runtime/src/codegen/SpikeCensus.cpp`, `.h` | A diagnostic tool, active only with `ECO_SPIKE_DIR`. | From notes | Keep if still useful |
| `runtime/src/main.cpp` (`ecor`) | An allocator and collector demo, not backend code. | From notes | Keep or move under `test/` |
| List head and tail folds | Off unless `ECO_MLIR_FOLD_LIST` is set. | Verified | Decide: turn them on or delete them |
| `EcoPipeline.cpp` | A commented-out "construct lowering" TODO. | From notes | Delete the comment |
| `test/fixtures/polyrec-mutual/` | A manual repro that only plans refer to. Nothing runs it. | From notes | Automate it or delete it |
| `runtime/src/codegen/EcoTypes.cpp`, `EcoTypes.h` | Near-empty files: the generated type definitions moved to `EcoDialect.cpp`, and the types are declared in `Ops.td`. The file's comment says it is kept for the include path and for future hand-written type helpers. | Verified | Keep, or fold into `EcoDialect.*` |
| `compiler/cmake/toolchain.cmake` Darwin x86_64 pins | Toolchain pins for Intel Macs, which are not supported. | From notes | Delete |
