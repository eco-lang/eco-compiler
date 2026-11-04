---
status: done
updated: 2026-11-04
---

# SourceIR catalogue: turning embedded-program tests into test logic

## Goal

`compiler/tests/TestLogic/` holds pipelines that run the `SourceIR` case programs through the
production compiler, usually checking an invariant. Checks and programs multiply: each new check
sees every catalogue program, and each new program is seen by every check. On 2026-11-04, 106
suites were moved out of `TestLogic` into unit-test folders, because none of them ran `SourceIR`
programs; each fed its own programs, written inline, to the pipeline. Classified one by one
(table: "The moved tests by kind" below), they fall into four kinds:

| Kind | Count | What it is |
|---|---|---|
| G | 26 | a check that holds for any valid program, fed only its own inline programs |
| N | 11 | invalid programs that must be rejected with a particular error |
| P | 39 | an outcome pinned for one particular program, often under non-default config |
| U | 30 | a module's API called on hand-built input; no program goes through the pipeline |

This plan turns the G and N tests into test logic over the catalogue, and moves their programs
into `SourceIR`:

1. The 17 G checks whose programs fit the standard catalogue now run over the whole catalogue,
   and their programs join it.
2. The program-independent checks hidden inside P tests become catalogue-wide checks.
3. A negative catalogue of invalid programs is built, each case recording the report title it
   must be rejected with, and the N tests move onto it.
4. The inline-program groups still inside SourceIR-driven TestLogic suites are extracted, to
   catalogue cases or to unit tests.

P and U tests stay unit tests (they are in the right place since the 2026-11-04 move). The 9 G
tests that need programs the catalogue cannot hold yet are listed under "Out of scope".

## Background

- The standard catalogue is `SourceIR.Suite.StandardTestSuites.expectSuite : (Src.Module ->
  Expectation) -> String -> Test`, over 86 case modules. The `SourceIR` case modules hold about
  1,100 labelled programs in all (a count of `label =` across `compiler/tests/SourceIR`, which
  includes the modules the standard catalogue leaves out). A case module decides nothing; the
  caller's expectation does.
- `TestLogic.TestPipeline` runs a program through `Compiler.Pipeline.Steps`, as `eco make` does
  (`runToCanonical` … `runToMlir`). Its results are `Result String …`: an error comes back as
  text, not as a report.
- A negative catalogue already exists: `SourceIR.TypeCheckFailsCases`, 12 ill-typed programs kept
  out of the standard catalogue. Three logics run it: `TypedErasedCheckingParityTest`
  (`expectEquivalentRejection`: both type-checking paths reject alike), `IdAssignmentTest` and
  `GlobalNamesTest` (invariants that hold even when type checking fails). Nothing checks that its
  programs are rejected, or with which error; its docstring says so.
- Two standard-catalogue logics (POST_010 `PostSolveNodeTypeGroundedTest`,
  `NodeVarConstrainedTest`) pass on any front-end error. No logic expects an error.
- `Compiler.BulkCheck.expectFailure` marks a case that reproduces a known bug (XFAIL with XPASS
  detection). It is not an intended rejection.
- Report titles come from the production reporters: `Compiler.Canonicalize.Error` (e.g. `NAME
  CLASH`, `SHADOWING`, `TOO MANY PARAMETERS`, `TOO MANY CAPTURED VARIABLES`, `TOO MANY FIELDS`,
  `ALIAS PROBLEM`, `CYCLIC DEFINITION`), the type error reporter (`TYPE MISMATCH`, `TOO MANY
  ARGS`, `INFINITE TYPE`, `BAD MAIN TYPE`, `BAD MAIN`), and `Builder.Reporting.Exit` for errors after
  type checking (`MONOMORPHIZATION ERROR`, `STAGE ARITY LIMIT`, chosen by message prefix).

## Decisions (2026-11-04, user)

- **Negative catalogue structure:** one case module per rejecting stage, so membership gives the
  stage. Six modules, in the order a build reaches them (`Compiler.Compile`, then the build's
  steps after it):

  | Module | Stage (`Compiler.Error` constructor) | Titles |
  |---|---|---|
  | `CanonicalizeFailsCases` | canonicalization (`BadNames`) | `NAME CLASH`, `SHADOWING`, `ALIAS PROBLEM`, `CYCLIC DEFINITION`, `CYCLIC VALUE`, `NAMING ERROR`, `TOO MANY ARGS`, … |
  | `LimitFailsCases` | canonicalization size limits (`BadNames`, `TooLarge`) | `TOO MANY PARAMETERS`, `TOO MANY CAPTURED VARIABLES`, `TOO MANY FIELDS` |
  | `TypeCheckFailsCases` (exists) | type checking (`BadTypes`) | `TYPE MISMATCH`, `TOO MANY ARGS`, `INFINITE TYPE`, … |
  | `PatternFailsCases` | pattern-match checking, `Compiler.Nitpick.PatternMatches` (`BadPatterns`) | `MISSING PATTERNS`, `UNSAFE PATTERN`, `REDUNDANT PATTERN` |
  | `MainFailsCases` | typed optimization's check of `main` (`BadMains`) | `BAD MAIN TYPE`, `BAD MAIN` |
  | `MonoFailsCases` | the build's steps after `Compiler.Compile`, reported by `Builder.Reporting.Exit` | `MONOMORPHIZATION ERROR`, `STAGE ARITY LIMIT` |

  `MainFailsCases` was added by the user (2026-11-04). `PatternFailsCases` is the stage between
  type checking and typed optimization; nothing tests its rejections today.

  Stages left without a module, because a `SourceIR` program (a `Src.Module` value) cannot reach
  them: syntax errors (`BadSyntax`; the program is already parsed), import errors (`BadImports`,
  `MODULE NOT FOUND`; raised when the build resolves a project's modules), `DEBUG REMNANTS` (only
  under `--optimize`, so it needs per-case config) and docs errors (`BadDocs`; only when docs are
  generated). Each would need source-text or project-level cases; out of scope.
- **Expected errors are recorded as report titles**, the text the user sees, not internal error
  constructors.

Consequences settled in this plan (not user decisions; revisit if wrong):

- A title can cover several errors (`NAME CLASH` is a duplicate value, type or constructor;
  `MONOMORPHIZATION ERROR` covers the spec watchdogs, `ValidateLimits` and unsupported
  expressions). A case may therefore also give an optional **message fragment**, a short piece of
  the rendered report that must appear (e.g. `"polymorphic recursion"`, the clashing name).
  The title is required; the fragment is for telling apart errors that share one.
- `LimitFailsCases` holds only the size limits that canonicalization enforces (HEAP_019,
  HEAP_078). A limit that only shows after specialization (`ValidateLimits`, HEAP_078) is a
  monomorphization rejection and goes in `MonoFailsCases`. So every module still names one stage.
- **The test pipeline does not check pattern matches.** `Compiler.Compile` runs
  `PatternMatches.check` between type checking and typed optimization; `TestLogic.TestPipeline`
  does not, so a catalogue program with a missing pattern compiles in the tests and fails under
  `eco make`. Phase 3 adds that step to the pipeline entry it builds, and a check that every
  standard-catalogue program passes it.
- Where a logic can compute the expected outcome from the program itself (a parameter count, a
  repeated top-level name), it does so (an _oracle logic_). It then runs over the valid catalogue
  too, which catches false rejections as well as missed ones. Case-recorded titles are for errors
  only a second compiler could predict, such as type errors.

## Phase 0: baseline

1. Record the elm-test count and duration from one full run
   (`cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`). At 2026-11-04:
   16,850 passed, 0 failed.
2. Record the coverage baseline (`compiler/scripts/coverage/cov.py baseline`; 95.1% in-scope
   branches at 2026-11-04), so the end of the plan can show nothing was lost.
3. Per new check, the cost is one pipeline run per catalogue program. Note the duration growth
   per phase; if a check costs more than about a minute over the catalogue, run it at the
   cheapest stage it needs (e.g. `runToPostSolve`, not `runToMlir`).

**Recorded 2026-11-04 (after the unit-test move):** elm-test 16,850 passed, 0 failed, 1,691 s
(`cmake --build build --target elm-tests`); coverage 8,963 / 9,428 in-scope branches (95.1%).

## Phase 1: the 17 G checks that fit the catalogue

For each module below:

1. Move its inline programs into a new `SourceIR/<Area>Cases.elm` (new modules, so parallel work
   never edits one file), add it to `StandardTestSuites`, and run every standard-catalogue logic
   over it. A program that breaks another logic has found either a bug or a wrong program. Expose a
   bug first (`expectFailure` plus a row in "Findings" below), then fix it.
2. Move the check (the `Src.Module -> Expectation` function and its helper module) to
   `TestLogic/<stage>/`, and give it a `…Test` that runs it over `StandardTestSuites`.
3. What pins a result for one program (an expected SCC grouping, a named function's type) stays
   in the unit test, which keeps only those pins. If nothing is left, delete the unit test.

| Unit test now | Check | Invariant | Notes |
|---|---|---|---|
| `Compiler.Type.CachedTypeInfoTest` | `expectTypeInfoCached` | CANON_006 | fully generic |
| `Compiler.Type.PostSolveDeterminismTest` | `expectDeterministicTypes` | POST_004 | fully generic |
| `Compiler.Type.PostSolveNoSyntheticVarsTest` | no synthetic var after PostSolve | POST_003 | uses `CompileThroughPostSolve`, its own canonicalize/constrain/PostSolve path: switch it to `TestPipeline.runToPostSolve` |
| `Compiler.Type.PostSolveGroupBTypesTest` | `expectGroupBTypesValid` | POST_001 | check already runs over the catalogue (`PostSolveGroupBStructuralTypesTest`): move the programs only |
| `Compiler.Type.NodeTypeVarNamesDistinctTest` | one variable name per solver root | — | 2 of 4 tests; the other 2 are P under the subst engine and stay |
| `Compiler.Type.DeepLetStackSafetyTest` | compiles (`expectCoverageRun`) | — | one 1,000-deep `let`; measure its cost per suite first; if large, keep it a unit test |
| `Compiler.Canonicalize.DependencySCCTest` | `expectValidSCCs` | CANON_005 | per-program expected groups stay as pins |
| `Compiler.Canonicalize.ImportResolutionTest` | `expectImportsResolved` | CANON_004 | fully generic |
| `Compiler.LocalOpt.Typed.TailDefTypesTest` | TailDef params, body and type match the annotation | TOPT_004, TOPT_005 | generalize from one named function to every annotated TailDef. TOPT_004 says its checker (`TestLogic/LocalOpt/TypePreservation.elm`) does not yet check calls, lets or functions: add the TailDef rule to that checker, not a new one |
| `Compiler.LocalOpt.Typed.TailLoopMutualRecCoverageTest` | SSA definedness, safepoint scoping | — | checks are already TestLogic; programs only (finding F5) |
| `Compiler.Monomorphize.AccessorPlaceholderCoverageTest` | compiles to MLIR | — | programs only (finding F8) |
| `Compiler.Monomorphize.DebugPolymorphismTest` | `expectDebugPolymorphismResolved` | MONO_009 | programs use Debug kernels, as `KernelIntrinsicCases` does |
| `Compiler.Monomorphize.Solver.LssLocalMultiEnrichTest` | a local use's annotation equals the definition's | — | generic over the whole graph |
| `Compiler.Monomorphize.Solver.NumberCompoundFieldTest` | numeric resolution, record layout, operand types | MONO_007, MONO_008, CGEN_040 | checks are already TestLogic; programs only (finding F2) |
| `Compiler.MonoOpt.Borrow.BorrowTailCallEscapeTest` | tail-call argument resources live to the end of the body | none (borrow design §8.5) | borrow is off by default: run under `borrow.enabled` (see Phase 2 note on config) or keep as is |
| `Compiler.MonoOpt.FunctionAccumulatorCoverageTest` | `expectHonestJoinStaging` | GOPT_003 | programs only (finding F6) |
| `Compiler.GenerateMlir.CmpiPredicateAttrTest` | every `arith.cmpi` has a predicate 0–9 | — | the "a Char `eco.case` exists" assertion stays as a pin |

`BorrowTailCallEscapeTest` needs a non-default flag. If no config-carrying catalogue run exists by
then, it stays a unit test and moves to "Out of scope".

**Done 2026-11-04.** 16 of 17 rows; 16 new case modules (`AccessorPlaceholderCases`,
`BorrowTailCallCases`, `CachedTypeInfoCases`, `CharCaseCases`, `DebugKernelCases`,
`DependencySCCCases`, `FunctionAccumulatorCases`, `GroupBLiteralCases`, `ImportResolutionCases`,
`LetPolyNameCases`, `LocalMultiEnrichCases`, `NumberCompoundFieldCases`,
`PostSolveDeterminismCases`, `SyntheticPlaceholderCases`, `TailDefTypeCases`,
`TailLoopMutualRecCases`); the catalogue now has 103 case modules. Deviations:
`DeepLetStackSafetyTest` stays a unit test (about 6.7 s per suite in the parallel run, a quarter
of the whole run); `PostSolveNoSyntheticVars` was deleted, since `PostSolveNoSyntheticHolesTest`
(POST_003) already checks the same more strictly; the TailDef rule went into
`TestLogic/LocalOpt/TypePreservation.elm`; the borrow check runs `Borrow.analyzeDefForTest` on the
default graph, so it needs no flag. The new checks found two compiler bugs (B1, B2 under "Findings", both since fixed; fixing B1 found B3, open, also under
"Findings"). Workspace run: 19,932 passed, 0 failed; the new work adds about 9.5% to the summed
test time.

## Phase 2: checks hidden in P tests

These P tests each contain a check that holds for any program. Before adding one, check that no
existing TestLogic checker covers it; `MonoGraphIntegrity` already checks MONO_011 and
`MonoNumericResolution.expectNoNumericPolymorphism` already checks that no `number` variable
survives monomorphization, so those two from `PostInlinePruneTest` and
`RenamingSubstAndMErasedTest` are dropped unless they check after a later pass than the existing
ones.

| Source | Check | Invariant |
|---|---|---|
| `LssPapMembersTest`, `LssHonestSourcesPipelineTest` | no empty lambda set in a stored registry type | LSS_001 |
| `LssHonestSourcesPipelineTest` | no false singleton at a join | LSS_026 |
| `LssVarCtorRowsTest` | no lambda-set variable left on a constructor row | — |
| `InlineSimplifyDestructCaptureTest` | no name bound twice in a body after the inliner | — |
| `PostInlinePruneTest` T5 | MONO_011 after the post-inline prune | MONO_011 (only if not already checked at that point) |

Each becomes a checker in `TestLogic/Monomorphize/` or `TestLogic/MonoOpt/` with a `…Test` over
`StandardTestSuites`. The P test keeps its program-specific assertions.

**Done 2026-11-04.** Four new catalogue-wide checks, each passing on the whole catalogue:
`TestLogic/Monomorphize/LambdaSetWellFormed` (LSS_001: no `LSet []`, members ascending, in every
type of the solver and optimized graphs), `LambdaSetJoinHonesty` (LSS_026: a join claiming `LSet js`
has only `LSet`/`LPartial` branches with members in `js`; few catalogue programs have such joins),
`PreMonoBinderHygiene` (no binder the pre-mono passes introduce shadows a name in scope, with the
pre-mono inliner off and on; `$` shadowing `$` in port encoders is in the input and allowed) and
`TestLogic/MonoOpt/PostPruneGraphClosed` (MONO_011 after the post-inline prune, which
`MonoGraphIntegrity` checks only before it and `Steps.checkPruned` only under `mono.validate`).
Dropped: the constructor-row `LVar` check, which fails on three valid catalogue programs because
`settleVarCtorRows` rightly leaves an `LVar` (read as ⊤) when a contributor is unknown, so it is not
an invariant; and the `number`-variable check, which `MonoNumericResolution` covers.

## Phase 3: the negative catalogue

### 3a. Case format

A new type in `SourceIR/Suite/`:

```elm
type alias Rejection =
    { title : String          -- the first report's title, e.g. "TYPE MISMATCH"
    , fragment : Maybe String -- optional text that must appear in the rendered report
    }
```

Each of the six modules exposes two suites:

- `expectSuite : (Src.Module -> Expectation) -> String -> Test`, as today, so the logics that run
  `TypeCheckFailsCases` keep working unchanged;
- `expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test`, for logics
  that need the recorded outcome.

`SourceIR.Suite.RejectedSuites` gathers all six, as `StandardTestSuites` does, and passes each
logic the stage of the module a case came from.

The existing 12 `TypeCheckFailsCases` programs get their titles (expected `TYPE MISMATCH` or
`INFINITE TYPE`; confirm each by running it).

### 3b. A pipeline entry that returns reports

``TestPipeline` returns errors as `String`, and it skips pattern-match checking. Add an entry that runs a program as far as it gets
through `Compiler.Pipeline.Steps` and returns the stage that rejected it and its reports, rendered
by the production reporters (canonicalize and type errors through `Compiler.Reporting`, later
errors through `Builder.Reporting.Exit`), with the stages in the order `Compiler.Compile` runs them,
pattern-match checking included. Add a standard-catalogue check that every valid program passes
pattern-match checking: a catalogue program that does not would fail under `eco make`.
`Compiler.Reporting.CompileReport` (a unit-test helper,
moved there on 2026-11-04) already compiles inline programs to reports for comparison with elm
0.19.1, so it is the starting point. `test/scripts/check-test-pipeline-production.sh` must still
pass: the entry may not call a pass module directly.

### 3c. The rejection logic

`TestLogic/Reporting/ExpectedRejectionTest.elm`, over `RejectedSuites`. For every case it checks
that:

- the program is rejected, not compiled;
- the rejection comes from the stage the case's module names (earlier stages succeed);
- the first report's title equals `title`, and `fragment`, if given, appears in it;
- the report renders without crashing.

The existing logics are extended where they make sense: `IdAssignment` and `GlobalNames` also over
`TypeCheckFailsCases`, `PatternFailsCases`, `MainFailsCases` and `MonoFailsCases` (all get past
canonicalization); the parity logic over every module from `TypeCheckFailsCases` on (for the later
modules both type-checking paths must accept).

`PatternFailsCases` is new and has no test to migrate. Seed it with the shapes the elm 0.19.1
reporter distinguishes: a missing constructor, a missing literal (`Int`, `Char`, `String`), a
missing list length, a missing record or tuple shape, a redundant branch after a wildcard and
after a full set of constructors, and a pattern that is missing in a `let` destructuring or a
function argument (`UNSAFE PATTERN`, `Compiler.Nitpick.Error`).

### 3d. Oracle logics

These compute the expected outcome from the program and run over the standard catalogue and the
negative catalogue together:

- **Size limits** (HEAP_019, HEAP_078): count each function's parameters, each lambda's parameters
  plus captures, each constructor's fields and each record's fields against
  `Compiler.IR.Runtime.HeapLimits`. Expect the matching `TOO MANY …` report exactly when a count is
  over its limit, and acceptance otherwise.
- **Name clashes** (CANON_003): scan the top-level values, types and constructors for repeats, and
  local bindings for names already bound by an enclosing scope of the module. Expect `NAME CLASH`
  or `SHADOWING` naming that name exactly when one exists.

### 3e. Moving the 11 N tests

| Unit test now | Goes to | Title(s) | Notes |
|---|---|---|---|
| `Compiler.Canonicalize.DuplicateDeclsTest` | `CanonicalizeFailsCases` + name-clash oracle | `NAME CLASH`, `SHADOWING` | fragment: the name; switch from calling canonicalize directly to the pipeline entry |
| `Compiler.Canonicalize.LimitErrorsTest` | `LimitFailsCases` + size-limit oracle | `TOO MANY PARAMETERS`, `TOO MANY CAPTURED VARIABLES`, `TOO MANY FIELDS` | the report text's HEAP_019/HEAP_078 reference becomes a fragment |
| `Compiler.Type.UnificationErrorsTest` | `TypeCheckFailsCases` | `TYPE MISMATCH` | its 5 valid control programs go to the standard catalogue |
| `Compiler.Type.OccursCheckTest` | `TypeCheckFailsCases` | `INFINITE TYPE` | fragment: the variable; 3 valid programs to the standard catalogue |
| `Compiler.Type.AnnotationEnforcementTest` | `TypeCheckFailsCases` | `TYPE MISMATCH` | fragment: the annotated name; 5 valid programs to the standard catalogue |
| `Compiler.Type.ErrorReportCoverageTest` | `TypeCheckFailsCases` | `TYPE MISMATCH`, `TOO MANY ARGS`, `INFINITE TYPE` | about 306 cases, with their fragments; the Error encode/decode round trip stays a unit test |
| `Compiler.Reporting.Render.TypePrintingCoverageTest` | `CanonicalizeFailsCases` (`ALIAS PROBLEM`), `MainFailsCases` (`BAD MAIN TYPE`, `BAD MAIN`) | as listed | its 2 unit tests of the localizer stay |
| `Compiler.Monomorphize.Solver.EngineSpecWatchdogTest` | polymorphic-recursion cases → `MonoFailsCases` | `MONOMORPHIZATION ERROR` | fragment `"polymorphic recursion"` (finding F13); the `specBreadth = 1` case needs per-case config and stays |
| `Compiler.Monomorphize.SpecWatchdogTest` | polymorphic recursion → `MonoFailsCases` | `MONOMORPHIZATION ERROR` | breadth and type-node limit cases need per-case config and stay, with its 7 unit tests |
| `Compiler.Monomorphize.ClosureLimitTest` | `MonoFailsCases` | `MONOMORPHIZATION ERROR` or `STAGE ARITY LIMIT` (confirm) | one slow generated program (700 functions, 2,100 captures): measure; if it slows every suite running `MonoFailsCases`, keep it a unit test |
| `Compiler.PreMono.ShaderTest` | `MonoFailsCases` | `MONOMORPHIZATION ERROR` | fragment `"shader"` (finding F9); needs a shader expression in a `SourceIR` program, which `SourceBuilder` may not build; its G half stays until shader programs are in the catalogue |

**Done 2026-11-04.** 403 negative cases: `CanonicalizeFailsCases` 24, `LimitFailsCases` 9,
`TypeCheckFailsCases` 338 (the 12 originals, 12 unification, 2 occurs-check, 6 annotation and 306
report cases), `PatternFailsCases` 12, `MainFailsCases` 12, `MonoFailsCases` 8. Every one is
rejected by its module's stage with its recorded title; the compiler accepted no invalid program
and crashed on none. Titles that differed from the guesses: three of the original
`TypeCheckFailsCases` programs are `INFINITE TYPE`, and the closure-limit program is `STAGE ARITY
LIMIT`. New: `SourceIR/Suite/{Rejection,RejectedSuites}`, `TestPipeline.runToReports` (the
`Compiler.Compile` stage order with pattern-match checking, then the build's steps, reports
rendered by the production reporters; `Stage` lives in `TestPipeline` to avoid a folder cycle),
`TestLogic/Reporting/ExpectedRejectionTest`, `TestLogic/Nitpick/PatternMatchesPassTest`, the oracles
`TestLogic/Canonicalize/{SizeLimits,NameClashes}Test` over `SourceFacts`, and the valid controls
`RejectionControlCases` (standard catalogue) and `LimitBoundaryCases` (programs at the size limits,
run only by the two oracles: a 2,047-parameter function in every suite took over 4.5 minutes and
11 GB). The shader case was written as source text, so F9 is a `MonoFailsCases` case.
Fragments are matched with whitespace collapsed. Workspace run: 17,183 passed, 0 failed.

## Phase 4: inline groups inside SourceIR-driven TestLogic suites

A scan of every TestLogic suite (2026-11-04) found 22 groups, 38 tests, of inline programs or
hand-built input mixed into suites that otherwise run the catalogue. None expects a rejection, so
the negative modules get nothing from here. Each group goes where it fits: (a) the program
becomes a catalogue case and the suite's check covers it there; (c) the assertion is specific
(a pin) or the input is hand-built, so it becomes a unit test; (a+c) both, the program to the
catalogue and the pin to a unit test.

| Suite: group | Tests | Kind | Target |
|---|---|---|---|
| `UnboxedBitmapTest`: wide record | 1 | a | new `SourceIR/WideObjectCases` |
| `UnboxedBitmapTest`: closure kind limits | 1 | a | `WideObjectCases`; also run `expectClosureKindLimits` over the whole catalogue |
| `UnboxedBitmapTest`: PAP of 26, 27 captures | 2 | a+c | `WideObjectCases` + `Compiler/GenerateMlir/ExprPapSlotKindsTest` |
| `UnboxedBitmapTest`: 30-Int record, 30-Int ctor, 28 mixed | 3 | a+c | `WideObjectCases` + `Compiler/GenerateMlir/OpsSlotKindsTest` |
| `DestructorTypeProjectionTest`: Result / Maybe / nested Result | 3 | a | `MaybeResultCases` (the "at least one `eco.project.custom`" check is a non-vacuity guard, not a pin) |
| `DestructorTypeProjectionTest`: ctor field 24 (Int, String, polymorphic), record field 27 | 4 | a+c | `WideObjectCases` + `Compiler/GenerateMlir/PatternsWideFieldProjectionTest` |
| `CharTypeMappingTest`: char ops in a lambda | 4 | a+c | `KernelIntrinsicCases` + `Compiler/GenerateMlir/IntrinsicsCharOpsTest` |
| `JoinpointUniqueIdTest`: `sumTo`, `count` | 2 | a | `TailRecCaseCases` |
| `CallAbiConsistencyTest`: wide ctor call | 1 | a | `WideObjectCases` (the 25-field ctor program is shared with `DestructorTypeProjectionTest`: add it once) |
| `ListConstructionTest`: user-defined `Cons`/`Nil` | 1 | a+c | `CaseCases` + `Compiler/GenerateMlir/OpsUserListCtorTest` |
| `ProjectionHeapLayoutConsistencyTest`: separate specializations | 1 | a | `SpecializePolyTopCases` |
| `SafepointRegionScopingTest`: tail-rec 3-ctor fan-out | 1 | a | `TailRecCaseCases`; also drop its re-runs of `TailRecCaseCases` and `IfLetSafepointCases`, which the standard catalogue already includes (its `CaseSafepointLeakCases` run stays) |
| `SingletonConstantsTest`: user-defined `True`/`False` | 1 | a+c | `CaseCases` + `Compiler/IR/Runtime/CtorTagTest` (calls `CtorTag.isEmbeddedConstantCtor` directly) |
| `JumpTargetTest`: checker on hand-built MLIR | 3 | c | `TestLogic/Generate/CodeGen/JumpTargetCheckerTest` |
| `MonoInlineSimplifyTest`: 4 fixtures with metric pins | 4 | a+c | programs to `LetCases`/`FunctionCases` only if not already in the catalogue; pins to `Compiler/MonoOpt/InlineSimplifyTest` |
| `MonoVarGlobalArityConsistencyTest`: top-level S, K, I | 1 | a | `CombinatorCases` |
| `MonoFunctionArityTest`: tail function returning a function | 1 | a | `CovTailRecCases` |
| `MonoNumericResolutionTest`: unannotated `double` at Int and Float | 1 | a | `SpecializeExprCases` (it must stay unannotated) |
| `LambdaIdUniquenessTest`: checker on hand-built graph | 2 | c | `TestLogic/GlobalOpt/LambdaIdUniquenessCheckerTest` |
| `UnscopedTailJumpTest`: `Expr.unscopedTailCallError` message | 1 | c | `Compiler/GenerateMlir/ExprUnscopedTailCallErrorTest` |

The two checker self-tests take a `CheckerTest` suffix because `<Checker>Test` names the catalogue
suite. Afterwards every TestLogic suite runs only catalogue modules, apart from checker self-tests
(`TypeEqTest`, `PapExtendResultCheckerTest` and the two above).

**Done 2026-11-04.** All 20 rows. New case module `SourceIR/WideObjectCases` (11 programs; the
25-field constructor shared by two suites added once); programs appended to `MaybeResultCases`,
`KernelIntrinsicCases`, `CaseCases`, `TailRecCaseCases`, `SpecializePolyTopCases`,
`SpecializeExprCases`, `CombinatorCases`, `CovTailRecCases`, `LetCases` and `FunctionCases` (two
`MonoInlineSimplify` fixtures were already in the catalogue). New unit tests:
`Compiler/GenerateMlir/{ExprPapSlotKinds,OpsSlotKinds,PatternsWideFieldProjection,IntrinsicsCharOps,OpsUserListCtor,ExprUnscopedTailCallError}Test`,
`Compiler/IR/Runtime/CtorTagTest`, `Compiler/MonoOpt/InlineSimplifyTest`, and the checker tests
`TestLogic/Generate/CodeGen/JumpTargetCheckerTest`, `TestLogic/GlobalOpt/LambdaIdUniquenessCheckerTest`.
`UnboxedBitmapTest` now runs `expectClosureKindLimits` over the whole catalogue too. A unit test
keeps its own copy of the program it pins (no unit test imports `SourceIR`). Workspace run: 17,091
passed, 0 failed; no moved program broke a catalogue check.

## Phase 5: earlier stages' checks over the later negative modules

A negative program is valid up to the stage that rejects it, so every earlier stage must handle it
and satisfy its invariants. The standard catalogue cannot hold programs that monomorphization
rejects, so before this phase nothing ran the PostSolve, typed-optimization or pre-mono checks on
polymorphic recursion over a non-regular type. **Done 2026-11-04 (user decision: the targeted
version):**

- `SourceIR.MonoFailsCases.expectBeforeMonoSuite`: its programs less the closure-limit one (seconds
  per run, width only).
- The 13 checks that run no further than PostSolve (`DependencySCC`, `ImportResolution`,
  `CachedTypeInfo`, `NodeTypeVarNamesDistinct`, `NodeVarConstrained` and the eight
  `TestLogic.Type.PostSolve` suites) also run `MainFailsCases` and `expectBeforeMonoSuite`; the six
  typed-optimization checks and `PreMonoBinderHygiene` run `expectBeforeMonoSuite`;
  `PatternMatchesPassTest` runs both. `PatternFailsCases` is not added: its programs are ordinary
  apart from the missing branch.
- One check was too strict: `TestLogic.LocalOpt.TypedOptTypes` called the shader's types
  (`WebGL.Shader`, `Math.Vector3.Vec3`) unknown; type checking builds them from
  elm-explorations/webgl and linear-algebra whatever the program imports, so they are now built-in
  types of the check, like `List` and `Json.Decode.Decoder`. No compiler bug was found.

## Gates

- After each phase: one full elm-test run (output to `/tmp/test_output.txt`), 0 failures; the
  pipeline-production check passes.
- At the end: a coverage re-baseline (`cov.py baseline`) at or above the Phase 0 figure, since
  tests are moved, not removed. A drop means a moved program lost a check or a stage.
- Bugs found by programs reaching new checks: exposed first as an `expectFailure` case and a row
  below, then fixed; a compiler fix also passes the full JIT E2E suite
  (`compiler/scripts/coverage/e2e-after-compiler-change.sh`).

**Final results (2026-11-04), after all four phases and the fixes of B1 to B6:**

- elm-test: 21,290 tests, 0 failed (16,850 before the plan), pipeline-production check ok. The one
  failure of the first final run was `GoldenConstraintTest` "top-level-vars", the only corpus
  entry with an unannotated recursive group, which moved because of the B3 fix; comparing the
  constraint strings before and after showed only the intended change, and the pair was
  re-recorded.
- Full JIT E2E: 2,594 / 2,594.
- Self-compile (`eco-boot`, the compiler type-checked and built by the fixed `guida.js`): passed,
  so no unannotated recursive group in the compiler relied on B3.
- Coverage: 8,978 / 9,442 in-scope branches (95.09%, against 95.07% at Phase 0). Only
  `Compiler.Type` changed: 13 new branches from the B1/B2/B3 fixes; three `Compiler.Type.Error`
  exclusions the negative catalogue showed to be reachable were removed (now covered); two new
  branches of the B1/B2 fixes were proven unreachable and excluded; four `Compiler.Type.Type` rows
  were re-anchored to the edited file.

## Citations dropped (2026-11-04)

Two tests cited invariant ids that `design_docs/invariants.csv` does not have. The citations are
removed from the test labels:

- `TOPT_TAILDEF_001` (`Compiler.LocalOpt.Typed.TailDefTypesTest`): the test checks that a
  `TailDef`'s parameters and body have the types its annotation declares. That is TOPT_004 (typed
  optimization preserves types) and TOPT_005 (function expressions carry their full type) applied to
  `TailDef`; the label now cites those two.
- `BORROW_005` (`Compiler.MonoOpt.Borrow.BorrowTailCallEscapeTest`): the test checks that every
  heap argument of a `MonoTailCall` is escape-seeded, live to the end of the function body, so
  reification never places a drop after a tail call (which would break the tail-call loop). That
  is the rule of `design_docs/globalopt/borrow-inference-design.md` §8.5, which says "BORROW_005
  pins both with a TestLogic check", but no BORROW_005 row exists (BORROW_002 to BORROW_005 are all
  absent; BORROW_006's row still lists BORROW_005 among its related ids). No other row states the
  rule, so the test now cites none. Whether to restore a row is left open.

## Findings

| Id | Found by | Symptom | Cause | Fix | Test | Status |
|---|---|---|---|---|---|---|
| B1 | `CachedTypeInfoTest` (CANON_006) | in an unannotated recursive group, later members get annotations with too few quantified variables: `f x = g x` / `g x = f x` gives `g : Forall {} (a -> b)`; a third member `h` gets `Forall {a}` | the members share their solver variables; `Compiler.Type.Type.toAnnotation` runs once per member and quantifies over the names taken in its naming scope, but its `getVarNames` walk skips classes an earlier member's walk left `getVarNamesMark` on, so their names are never taken. Stock Elm 0.19.1 (`Type.toAnnotation`) has the same bug: with `A exposing (f, g)` as above, `elm make` of a module using `A.g` crashes with `Map.!: given key is not an element in the map` (using `A.f` compiles) | `toAnnotation` also quantifies over every name the converted type mentions (new `addTypeVarNames`) | `CachedTypeInfoTest` "Unannotated recursive groups" (groups of two and three; expected-failure wrapper removed) | fixed |
| B2 | `NodeTypeVarNamesDistinctTest` | a let helper's generalized `number` variable is named like one of the enclosing annotation; under the subst engine `h y z = y * z` in `wrapInt` is specialized at `Float` though called with `Int` literals | the naming, not the subst engine: both variables are instantiated from `(*)`'s annotation, so both carry the name `number` (`srcTypeToVariable` keeps scheme names). `toAnnotation` keeps it for `x`'s variable and marks it; `Type.toCanTypeBatch` reserved the annotations' names only for generated names, and its `getVarNames` walk, which skips the marked variable, saw no clash, so the helper's variable kept `number`. Monomorphization identifies variables by name within a definition, so the subst engine merged them | `toCanTypeBatch` walks with the new `getVarNamesAvoiding annotationNames`; `addName` treats a reserved name as held by another variable, so the helper's variable becomes `number2` | `TestLogic.Type.NodeTypeVarNamesDistinctTest` (tolerance and wrapper removed; catalogue strict) and `Compiler.Type.NodeTypeVarNamesDistinctTest` (Stage5 pin now a plain test: `y`, `z` at `MInt`, no `y` at `MFloat`) | fixed |
| B3 | found while fixing B1 (`NodeTypeVarNamesDistinct` on a group of three) | type checking accepts ill-typed unannotated recursive groups: `f x = g x` / `g y = if y then f 3 else f 4` is accepted with `f : number -> a`; in a group of three, a member's argument pattern and its use are different variables both named `a` | `Compiler.Type.Constrain.Typed.Expression.recDefsHelpWithIds` threads the flex variables gathered so far into the next unannotated member's pattern state, so an earlier member's variables are declared in the next member's `CLet`, which generalizes them; a later `CLocal` of the earlier member's argument is then a fresh instance. Same code in stock Elm 0.19.1, which accepts the program too | `recDefsHelpWithIds` starts each unannotated member's pattern state empty and adds its variables to the group's (`Info (props.vars ++ flexVars)`), so they are declared once, in the group's `CLet`; applied 2026-11-04 on the user's decision. Eco now rejects these programs where stock Elm accepts them | `TypeCheckFailsCases` group "Unannotated recursive groups" (the argument repro, and the user's result repro: stock Elm's output crashes with `str.toUpperCase is not a function`); `RankPolymorphismTest` and `NodeTypeVarNamesDistinctTest` (plain tests now) | fixed |
| B4 | `PatternMatchesPassTest` | 21 standard-catalogue programs (refutable list or literal patterns in function, lambda or `let` arguments) are rejected by `eco make` with `UNSAFE PATTERN` | invalid test programs, accepted only because the test pipeline skipped pattern-match checking | each rewritten as a valid program: the refutable part moved into a `case` with the missing alternatives, irrefutable tuple, record and alias parts kept in argument position; the original kept as an `UNSAFE PATTERN` case | `PatternFailsCases` group "Catalogue unsafe patterns"; `PatternMatchesPass` has no exceptions | fixed |
| B5 | `ExpectedRejectionTest` | polymorphic recursion and unsupported constructs (shaders) were reported as "This is likely a compiler bug" | `Builder.Reporting.Exit.toGenerateReport` spared only the `specialization ` and `STAGE ARITY LIMIT` prefixes | new `isProgramCondition` also recognizes `polymorphic recursion cannot be monomorphized: ` and `MonoSolver.unsupported: ` | `Builder.Reporting.ExitTest` | fixed |
| B6 | Phase 3 review | `test/scripts/check-test-pipeline-production.sh` forbade only pre-reorg module names, so it guarded nothing | the reorg renamed every pass module | the list names the current pass modules (`Compiler.PreMono.EntryPrep` allowed: the harness imports it for a type only) | negative control: an `import Compiler.MonoOpt.InlineSimplify` line is caught | fixed |

## Out of scope

- **The other 9 G tests**, which need programs the catalogue cannot hold yet: port modules
  (`PortUnitCoverageTest`), effect-manager modules (`EffectManagerCoverageTest`; the mock
  interfaces lack `Platform` and `Task`), shader programs (`ShaderCoverageTest`), programs calling
  fake kernels (`LocalOptPathsCoverageTest`, `PostSolveKernelTypesTest`), per-case config
  (`LoopifyLastRoundCaptureTest`, `BinopSchemeTypeLeakTest`), excluding a case from named suites
  (`ChosenFunctionValuesTest`, whose programs break another suite on purpose), and source-text
  cases (`SolverCoverageTest`). Each needs its own catalogue addition; a follow-up plan.
- **Per-case config**, which would also bring in the spec-watchdog limit cases.
- **The 39 P tests and 30 U tests.** They stay unit tests.

## The moved tests by kind

The full table, per module with pipeline use, config, invariants and catalogue fit, was produced on
2026-11-04 and summarized here. G and N are listed in Phases 1 and 3; the G tests out of scope are
listed above. P: the `Lss*` lambda-set tests, the dispatch and devirtualization tests (E2V2, E5,
E9, E92, spine PAP), the pre-mono pass tests (AliasForward, EtaExpand, InlineSimplify,
EtaExpandStageCap), AggPromote, HoleyAliasLocalRec, PostInlinePrune, TailFuncSpecialization,
GoldenConstraint, KernelIntrinsics, RankPolymorphism, InfiniteFloatLiteral, BackendNoMain and
others. U: union-find, the type-state IO codes, the MLIR bytecode encoders, AbiCloning on
hand-built IR, the CAF passes, the arrow and alias memos, kernel licenses, `Config.hash`, and
others.
