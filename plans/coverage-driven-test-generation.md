# Coverage-Driven Test Generation Plan

## Goal

Systematically increase test coverage of the compiler's backend pipeline
(Type → PostSolve → Monomorphize → GlobalOpt → MLIR) to **>95% of reachable
code** by iteratively adding SourceIR test cases guided by coverage reports.

"Reachable code" excludes error-reporting paths (e.g., `Type.Error`,
`SolverSnapshot`), CLI/terminal code, and dead code that cannot be triggered
by valid Elm input through the pipeline. For unreachable modules, document
why coverage cannot be improved and mark them done.

New test cases must be **valid Elm code** — they must pass canonicalization,
type checking, and nitpicking. However, they **may fail** in later stages
(Monomorphization, GlobalOpt, MLIR generation). Finding such failures is the
entire point: they reveal bugs in the backend pipeline that need fixing.

## Prerequisites

- Coverage tool: `compiler/elm-coverage/` (modified for elm-test-rs)
- Test driver: `compiler/tests/TestLogic/TypedPipelineTest.elm` — runs all
  StandardTestSuites through the full pipeline using `expectCoverageRun`,
  which passes as long as the test case is valid Elm (passes through
  TypedOpt). Failures in Mono/GlobalOpt/MLIR are reported but do not
  fail the test.
- File list: `/work/elm-cov-file.csv` — 36 .elm files ordered by compiler phase,
  with a `done` column for tracking progress across sessions
- Test cases: `compiler/tests/SourceIR/` — parametric test modules using
  `Compiler.AST.SourceBuilder` to construct Elm AST fragments

## Commands

### Generate coverage JSON (TypedPipelineTest only, max 8 workers)

**IMPORTANT**: Only `TypedPipelineTest.elm` is used for coverage measurement.
Use the `--filter "coverage run"` flag to ensure only this test file runs.

```bash
cd /work/compiler
env PATH="$(pwd)/node_modules/.bin:$PATH" \
  node elm-coverage/bin/elm-coverage src/ \
    --tests tests/ \
    --elm-test elm-test-rs \
    --report json \
    --force \
    -- --workers 8 --fuzz 1 --filter "coverage run"
```

Output: `compiler/.coverage/coverage.json` (summary) and per-module files
like `compiler/.coverage/Compiler/Type/Type.json` (detailed annotations).

### Run TypedPipelineTest standalone (no coverage)

```bash
cd /work/compiler
npx elm-test-rs --project build-xhr --fuzz 1 --filter "coverage run"
```

**Note**: All coverage and validation runs use only
`compiler/tests/TestLogic/TypedPipelineTest.elm` via `--filter "coverage run"`.
No other test files are involved in this workflow.

## Coverage JSON Format

There are two levels of coverage data:

### Summary (`coverage.json`)

```json
{
  "modules": [
    {
      "module": "Compiler.Type.Type",
      "totalComplexity": 65,
      "coverage": {
        "declarations": { "covered": 39, "total": 48 },
        "letDeclarations": { "covered": 3, "total": 5 },
        "lambdas": { "covered": 24, "total": 63 },
        "caseBranches": { "covered": 24, "total": 74 },
        "ifBranches": { "covered": 5, "total": 17 }
      }
    }
  ]
}
```

### Per-module detail (e.g. `.coverage/Compiler/Type/Type.json`)

```json
{
  "module": "Compiler.Type.Type",
  "totalComplexity": 65,
  "coverage": { ... },
  "annotations": [
    {
      "type": "declaration",
      "count": 0,
      "from": { "line": 622, "column": 1 },
      "to": { "line": 627, "column": 12 },
      "name": "toErrorType",
      "complexity": 1
    }
  ]
}
```

- `annotations[i].type` ∈ { "declaration", "letDeclaration", "lambdaBody", "caseBranch", "ifElseBranch" }
- `annotations[i].count` = hit count (zero means uncovered)
- `annotations[i].from` / `.to` = source location

## Test Validity Rules

### Must pass (test case is invalid if these fail)
1. **Canonicalization** — the AST must be well-formed
2. **Type checking** — the module must type-check without errors
3. **PostSolve** — type fixups must succeed
4. **Typed optimization** — nitpicking, pattern exhaustiveness, etc.

If a test case fails any of these stages, it is **not valid Elm code** and
must be discarded or fixed. The `expectCoverageRun` function in
`TestPipeline.elm` will fail the test in this case.

### May fail (this is what we want to find)
5. **Monomorphization** — specialization, closure conversion, etc.
6. **Global optimization** — inlining, staging, ABI cloning, etc.
7. **MLIR generation** — lowering to MLIR ops

If a test case fails at stages 5-7, the test still passes (the code was
valid Elm), but the failure is logged. These failures represent **bugs in
the backend pipeline** that should be investigated and fixed separately.

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

1. Read the module's per-module coverage JSON from
   `compiler/.coverage/<path>/<Module>.json`.
2. List all annotations with `count == 0`.
3. Group them by function/declaration to understand which code paths are missed.

### Step 2 — Reason about test cases

1. Read the actual source of the uncovered functions (use the `from.line`/`to.line`
   from the coverage report to locate them).
2. Determine what kind of Elm input would exercise those code paths. Consider:
   - Pattern match branches that need specific constructor shapes
   - Type-driven paths (e.g., unboxed Int/Float/Char vs boxed types)
   - Edge cases: empty lists, unit, nested records, recursive types
   - Kernel function calls that trigger specific ABI paths
   - Polymorphic vs monomorphic specialization paths
   - Constrained type variables (`number`, `comparable`, `appendable`)
   - Type alias usage in annotations
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

**Important**: Test cases must be valid Elm. They must pass canonicalization,
type checking, and nitpicking. If a test case fails these early stages, fix
or discard it. Failures in Mono/GlobalOpt/MLIR are expected and welcome —
they reveal backend bugs.

### Step 4 — Measure coverage delta

1. Re-run the coverage command (see Commands above).
2. Compare the module's annotation counts with the previous run.
3. Note which previously-zero annotations now have non-zero counts.

### Step 5 — Evaluate and iterate

- **If new coverage was gained**: Keep the test cases. If the module still has
  significant uncovered areas, go to Step 2 for another round on the same module.
- **If no new coverage was gained**: The test cases don't reach the target paths.
  Discard them (revert), re-analyze, and try a different approach in Step 2.
- **If the module has good coverage (>95% of reachable expressions)**: Mark the
  file `done` in the CSV and move to the next file.
- **If the remaining uncovered code is unreachable** (error paths, dead code,
  CLI-only paths): Document why in a comment and mark done. Unreachable code
  does not count against the 95% target.

### Step 6 — Validate

After processing each file, run the full TypedPipelineTest to ensure all tests
still pass (i.e., all test cases are valid Elm):

```bash
cd /work/compiler
npx elm-test-rs --project build-xhr --fuzz 1 --filter "coverage run"
```

Tests that fail in Mono/GlobalOpt/MLIR will still pass (they are valid Elm).
Tests that fail in canonicalization/type-checking will fail and must be fixed.

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

- The TypedPipelineTest uses `expectCoverageRun` which calls the full pipeline
  but only requires success through TypedOpt. Failures in Mono/GlobalOpt/MLIR
  are logged via `Debug.log` but the test passes (the input was valid Elm).
- Some modules (e.g., error reporting, Terminal.*) won't be covered by this
  approach — they require failure paths or CLI interaction. Ignore them.
- The `--filter "coverage run"` flag ensures only TypedPipelineTest tests run,
  keeping coverage focused and iteration fast (~20s per run).
- Use `--force` with elm-coverage so the report is generated even if some tests
  fail (e.g., due to `Test.skip`).
- **Resumability**: The loop is designed to be stopped and restarted across
  sessions. All state is in two files: the `done` column in
  `/work/elm-cov-file.csv` (which file to process next) and the committed test
  cases in `compiler/tests/SourceIR/` (accumulated coverage). A fresh coverage
  report is always regenerated on resume so it reflects the current test suite.
