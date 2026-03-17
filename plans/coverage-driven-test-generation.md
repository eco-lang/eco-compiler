# Coverage-Driven Test Generation Plan

## Goal

Systematically increase test coverage of the compiler's backend pipeline
(Type → PostSolve → Monomorphize → GlobalOpt → MLIR) by iteratively adding
SourceIR test cases guided by coverage reports.

## Prerequisites

- Coverage tool: `compiler/elm-coverage/` (modified for elm-test-rs)
- Test driver: `compiler/tests/TestLogic/TypedPipelineTest.elm` — runs all
  StandardTestSuites through the full pipeline to MLIR with no condition
  beyond "doesn't crash"
- File list: `/work/elm-cov-file.csv` — 36 .elm files ordered by compiler phase,
  with a `done` column for tracking progress across sessions
- Test cases: `compiler/tests/SourceIR/` — parametric test modules using
  `Compiler.AST.SourceBuilder` to construct Elm AST fragments

## Commands

### Generate coverage JSON (TypedPipelineTest only, max 8 workers)

```bash
cd /work/compiler
env PATH="$(pwd)/node_modules/.bin:$PATH" \
  node elm-coverage/bin/elm-coverage src/ \
    --tests tests/ \
    --elm-test elm-test-rs \
    --report json \
    --force \
    -- --workers 8 --fuzz 1 --filter "generates MLIR"
```

Output: `compiler/.coverage/coverage.json`

### Run TypedPipelineTest standalone (no coverage)

```bash
cd /work/compiler
npx elm-test-rs --project build-xhr --fuzz 1 --filter "generates MLIR"
```

## Coverage JSON Format

The JSON report is an object keyed by module name (e.g. `"Compiler.Monomorphize.Specialize"`).
Each entry contains:

```json
{
  "coverageData": [0, 3, 0, 1, ...],
  "expressions": [
    {
      "complexity": 1,
      "type": "declaration",
      "startLine": 42, "startCol": 1,
      "endLine": 55, "endCol": 10,
      "count": 3
    },
    ...
  ]
}
```

- `coverageData[i]` = hit count for expression `i`
- `expressions[i].type` ∈ { "declaration", "letDeclaration", "lambdaBody", "caseBranch", "ifElseBranch" }
- `expressions[i].count` = same as `coverageData[i]`
- A zero count means the expression was never executed

## Resumable Progress Tracking

The CSV file `/work/elm-cov-file.csv` has four columns: `file`, `module`,
`phase`, and `done`. When a module has been fully processed (coverage improved
or determined unreachable), mark it by writing `yes` in the `done` column.

### On startup / resume

1. Read `/work/elm-cov-file.csv`.
2. Find the first row where `done` is empty — this is the current file.
3. Generate a fresh coverage JSON report (see Commands).
4. Continue the work loop from that file.

Files already marked `done` are **never re-processed**. This allows the loop to
be stopped at any point and resumed in a new session without losing progress.

### Marking a file done

After Step 5 (Evaluate), when moving on to the next file, update the CSV:

```
compiler/src/Compiler/Type/Type.elm,Compiler.Type.Type,1-type-infrastructure,yes
```

Do this before starting work on the next file so that progress is saved even if
the session is interrupted immediately after.

## Work Loop

For each file in `/work/elm-cov-file.csv` (processed in order, skipping rows
where `done` is non-empty):

### Step 1 — Identify uncovered code

1. Read the module's entry from `compiler/.coverage/coverage.json`.
2. List all expressions with `count == 0`.
3. Group them by function/declaration to understand which code paths are missed.

### Step 2 — Reason about test cases

1. Read the actual source of the uncovered functions (use the `startLine`/`endLine`
   from the coverage report to locate them).
2. Determine what kind of Elm input would exercise those code paths. Consider:
   - Pattern match branches that need specific constructor shapes
   - Type-driven paths (e.g., unboxed Int/Float/Char vs boxed types)
   - Edge cases: empty lists, unit, nested records, recursive types
   - Kernel function calls that trigger specific ABI paths
   - Polymorphic vs monomorphic specialization paths
3. Check if any existing SourceIR test case already covers a similar shape.

### Step 3 — Add test cases

1. Pick the most appropriate existing `SourceIR/*Cases.elm` file, or create a
   new one if the language feature is genuinely new.
2. Add test cases using `Compiler.AST.SourceBuilder`:
   - Use `makeModule`/`makeModuleWithDefs`/`makeModuleWithTypedDefs` to build
     the AST
   - Each test case defines a `testValue` expression exercising the target path
   - Add the case to the module's `expectSuite` list
3. If a new `SourceIR/*Cases.elm` file is created, also add it to
   `SourceIR/Suite/StandardTestSuites.elm`.

### Step 4 — Measure coverage delta

1. Re-run the coverage command (see Commands above).
2. Compare the module's `coverageData` with the previous run.
3. Note which previously-zero expressions now have non-zero counts.

### Step 5 — Evaluate and iterate

- **If new coverage was gained**: Keep the test cases. If the module still has
  significant uncovered areas, go to Step 2 for another round on the same module.
- **If no new coverage was gained**: The test cases don't reach the target paths.
  Discard them (revert), re-analyze, and try a different approach in Step 2.
- **If the module has good coverage (>70% of reachable expressions)**: Mark the
  file `done` in the CSV and move to the next file.

### Step 6 — Validate

After processing each file, run the full TypedPipelineTest to ensure all tests
still pass:

```bash
cd /work/compiler
npx elm-test-rs --project build-xhr --fuzz 1 --filter "generates MLIR"
```

## File Processing Order

Files are processed in compiler phase order (from `/work/elm-cov-file.csv`):

1. **Phase 1-2: Type infrastructure & checking** (10 files)
   - `Compiler.Type.Type`, `UnionFind`, `Error`, `Instantiate`, `Occurs`,
     `Unify`, `Solve`, `SolverSnapshot`, `KernelTypes`, `PostSolve`
2. **Phase 5: Monomorphization** (10 files)
   - `State`, `Registry`, `TypeSubst`, `Analysis`, `Specialize`, `KernelAbi`,
     `Closure`, `MonoTraverse`, `Prune`, `Monomorphize`
3. **Phase 6: Global optimization** (5 files)
   - `Staging`, `MonoInlineSimplify`, `MonoGlobalOptimize`, `AbiCloning`,
     `MonoReturnArity`
4. **Phase 7: MLIR generation** (11 files)
   - `Types`, `Names`, `Ops`, `Context`, `TypeTable`, `Intrinsics`,
     `Patterns`, `Lambdas`, `Expr`, `Functions`, `Backend`

Earlier phases are processed first because their coverage gaps may indicate
fundamental input shapes that, once added, also improve later-phase coverage.

## Notes

- The TypedPipelineTest uses `expectMLIRGeneration` which calls `runToMlir`,
  exercising the full pipeline: Canonicalize → TypeCheck → PostSolve →
  TypedOpt → Mono → GlobalOpt → MLIR.
- Some modules (e.g., error reporting, Terminal.*) won't be covered by this
  approach — they require failure paths or CLI interaction. Ignore them.
- The `--filter "generates MLIR"` flag ensures only TypedPipelineTest tests run,
  keeping coverage focused and iteration fast (~20s per run).
- Use `--force` with elm-coverage so the report is generated even if some tests
  fail (e.g., due to `Test.skip`).
- **Resumability**: The loop is designed to be stopped and restarted across
  sessions. All state is in two files: the `done` column in
  `/work/elm-cov-file.csv` (which file to process next) and the committed test
  cases in `compiler/tests/SourceIR/` (accumulated coverage). A fresh coverage
  report is always regenerated on resume so it reflects the current test suite.
