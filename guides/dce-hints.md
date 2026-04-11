# DCE Hints

## Baseline

- **elm-test**: 12,477 passed, 0 failed
- **E2E**: (to be recorded on first LOOP run)
- **Coverage**: decls 42%, let decls 56%, lambdas 48%, branches 32%

## Candidates

| # | Module | Symbol / region | Coverage | Status | Notes |
|---|--------|----------------|----------|--------|-------|
| 1 | Compiler.GlobalOpt.AbiCloning | `computeCaptureAbi`, `collectFromExpr`, `collectFromDef`, `recordCallAbis` | 0% | FIXED | Removed 4 dead internal functions + unused `Dict` import. `abiCloningPass` kept as no-op stub. |
| 2 | Compiler.Monomorphize.MonoTraverse | `mapExpr`, `mapDef`, `mapDecider`, `mapChoice`, `mapExprChildren` | 0% | FIXED | Removed 5 dead map functions (4 public + `mapExprChildren` helper). `traverse*` and `fold*` families retained. |
| 3 | Compiler.Type.SolverSnapshot | `fromSolveResult`, `withLocalUnification`, `specializeFunction`, `specializeChained`, `specializeChainedWithSubst`, `LocalView` + 20 helpers | 0% | FIXED | Removed 5 exported functions, 1 type alias, and ~20 internal helpers (walkAndUnify, monoTypeToVar, buildLocalView, etc.). Kept `resolveVariable`, `SolverState`, `SolverSnapshot`, `TypeVar`. Removed 10 unused imports. |
| 4 | Compiler.Generate.MLIR.Expr | `boxArgsWithMlirTypes` | 0% | FIXED | Removed function and its entry in the exposing clause. |

## Deep Candidates (dead branches / unreachable crashes inside live functions)

These require slightly more care — removing a branch, simplifying a match,
or restructuring code so an impossible case falls out of the type system.

| # | Module | Location | What | Status | Notes |
|---|--------|----------|------|--------|-------|
| 5-10 | Various MLIR.Expr | Defensive crash guards | Various | SKIPPED | Defensive crash branches inside live functions. Structurally unreachable but serve as invariant documentation. Low value to remove, risk of hiding real bugs. |
| 11-14 | Various Type modules | Defensive crash guards | Various | SKIPPED | Same — crash guards after exhaustive pattern matches. Good defensive programming, not worth removing. |
| 15-16 | Type.PostSolve | Group A dispatch fallbacks | Various | SKIPPED | Dead by dispatch design but removing risks regression if dispatch logic changes. |
| 17-18 | Monomorphize.Specialize | Accessor/Nothing cycle crashes | Various | SKIPPED | Structurally impossible but document important invariants. |
| 19-21 | GlobalOpt.MonoGlobalOptimize | Catch-all branches | Various | SKIPPED | Defensive catch-alls returning safe defaults. Low value to remove. |
| 22-23 | MLIR Functions/Patterns | Enum/ctor/layout fallbacks | Various | SKIPPED | May be reachable for user-defined types not yet tested. Safer to keep. |
| 24-25 | BytesFusion.Reify | Kernel decode/encode stubs | Various | SKIPPED | Functions are called but return Nothing as stubs. Not DCE — would need interface changes to remove. |
| 26 | MonoInlineSimplify | Redundant leaf branches | Various | SKIPPED | Refactoring, not DCE. Branches are correct, just verbose. |

## False Positives (NOT dead)

| Module | Why not dead |
|--------|-------------|
| Compiler.Type.SolverRoots | All 4 exports called from Compile.elm; 0% coverage = untested typed-compilation path |
| Compiler.Type.Error | All exports called from error reporting / Unify; low coverage = error paths rarely exercised |
| Compiler.Generate.MLIR.Backend | `backend` is test-only but `streamMlirToWriter`/`streamMlirBytecode` are production; low coverage = streaming paths undertested |
| Compiler.Generate.MLIR.BytesFusion.Reify | All functions have internal callers; low coverage = many encoder/decoder patterns untested |
| Compiler.Generate.MLIR.BytesFusion.Emit | All functions have internal callers; low coverage = many emit paths untested |
| Compiler.Generate.MLIR.Functions | `generateClosureFuncWithClones`, `generateManagerLeaf` are called internally |
| Compiler.Generate.MLIR.Patterns | `hexDigitToInt`, `boxPrimitive` are called internally |
| Compiler.GlobalOpt.MonoGlobalOptimize | All 36 internal helpers have callers |
| Compiler.GlobalOpt.MonoInlineSimplify | All 74 internal helpers have callers |
| Compiler.GlobalOpt.Staging.Rewriter | All 14 internal helpers have callers |
| Compiler.Monomorphize.KernelAbi | All uncovered functions are called internally |
| Compiler.Monomorphize.Monomorphize | All uncovered functions are called internally |
| Compiler.Monomorphize.State | `lookupVarHelp` is called from `lookupVar` |
