---
status: partial
updated: 2026-11-05
remaining: "9 tracker modules still open (2026-11-04 re-baseline: in-scope branches 95.1%): Monomorphize.Solver LssInfer/Monomorphize/Store/Translate, MonoOpt.AbiCloning, GenerateMlir Expr/Patterns/Ops/BytesFusion.Reify. The rest are branches no round could reach or prove dead (reasons in tracker notes). Done when every row of compiler/coverage/tracker.csv is done, unreachable or flag-gated."
---

# Coverage-Driven Test Generation

## Goal

Raise test coverage of the typed compiler pipeline, from type checking to MLIR, to **≥ 95% of
reachable branches in every module**, by adding tests where a coverage report shows code that no
test reaches. Tests that make the compiler fail are wanted: they expose bugs, which are recorded as
expected-failure tests first and fixed afterwards.

## Decisions (2026-11-03)

- **Combined coverage.** Coverage is the union of the elm-test-rs suite and the JIT E2E suite. A
  branch either suite reaches is covered; the loop writes tests only for what neither reaches.
- **Default flags only.** Code that runs only under a non-default `Compiler.Config` setting (CSE,
  CAF dedupe/hoist/census, borrow inference, `list.mapTemplate`, `mono.validate`, the Subst and Diff
  mono engines, census reports) is excluded, not tested.
- **Type error reporting is in scope**: `Compiler.Type.Error`, `Compiler.Type.ErrorType` and
  `Compiler.Reporting.Render.Type*`, reached by programs that fail type checking and have their
  error rendered.
- **Crash code is excluded, and a hit on it is a bug.** A branch or body that calls
  `System.Crash.crash` / `Eco.Crash.crash` / `Debug.todo` directly (or through a module-local helper
  whose body is a crash) marks a state the compiler should never reach. It does not count toward
  coverage, and every report lists any crash annotation that a test did reach.

## History

The first version of this plan (2025) set up `compiler/elm-coverage` and
`TestLogic.TypedPipelineTest` and listed 36 files in `/work/elm-cov-file.csv`. Its loop was never
recorded as complete; the CSV was deleted as a stray file in 94a1e6b48b, and its module names
predate the November 2026 source-tree reorganization. On 2026-11-03 the tooling was revived and
extended to E2E, and this plan was rewritten around it.

## Scope

In-scope modules (prefixes, `SCOPE_PREFIXES` in `compiler/scripts/coverage/cov.py`):

`Compiler.Type.*`, `Compiler.Reporting.Render.Type*`, `Compiler.LocalOpt.Typed.*`,
`Compiler.PreMono.*`, `Compiler.Monomorphize.*`, `Compiler.MonoOpt.*`, `Compiler.GenerateMlir.*`,
`Mlir.*` (112 modules). Modules and lines excluded from the measure are listed in
`compiler/coverage/exclusions.csv`.

**Measure.** Case and if branches (`caseBranch`, `ifElseBranch` annotations of elm-instrument),
excluding crash code and `exclusions.csv`. Declarations are reported alongside; an unreached
declaration is always worth a look.

**Baseline 2026-11-03:** in-scope branches 8,119 / 11,886 (68.3%), declarations 2,394 / 2,648
(90.4%). By folder: Type 50%, Reporting 38%, LocalOpt 83%, PreMono 58%, Monomorphize 74%,
MonoOpt 71%, GenerateMlir 68%, Mlir 82%.

## Files

| Path | What |
|---|---|
| `compiler/scripts/coverage/cov.py` | the driver: `setup`, `baseline`, `quick`, `report`, `workspace`, `diff` |
| `compiler/coverage/tracker.csv` | one row per in-scope module: status, current and baseline coverage, notes (committed) |
| `compiler/coverage/exclusions.csv` | `module,line,kind,reason`; `line` = `*` excludes the whole module; kinds `flag`, `unreachable` |
| `compiler/coverage/findings.csv` | compiler bugs the loop exposed: id, module, stage, test, symptom, status |
| `compiler/elm-coverage/` | the elm-coverage fork; `bin/elm-instrument-eco` repairs elm-instrument's output |
| `compiler/tests/Compiler/BulkCheck.elm` | `expectFailure`: an expected-failure wrapper for a `TestCase` |
| `build/coverage/baseline/` | the stored baseline: `info.json`, counts per suite, per-module source hashes |
| `build/coverage/quick/<tag>.json` | the counts of one quick run (tag = workspace name, or `main`) |

`exclusions.csv` rows carry an `anchor` (the stripped text of the row's first line) and a `decl`
(the enclosing top-level definition), so a row follows its code when a module is edited and never
moves out of its definition; `cov.py exclusions --rewrite` writes moved line numbers back, and
fills missing anchors and decls only in modules unchanged since the baseline.

How the report treats exclusions:
- `flag`: excludes what E2E does not reach. E2E runs at the default flags, so a default-path guard
  inside a gated range is measured. elm-test runs non-default configurations on purpose, so its
  hits on flag code mean nothing.
- `unreachable`: any hit is listed under "EXCLUDED AS UNREACHABLE BUT REACHED"; the row is wrong.
- Whole-module (`*`) rows are exempt from both (a gated module's empty-stats values and guards run).

`tracker.csv` status values: `open`, `active` (an agent is on it), `done` (≥ 95% of reachable
branches, and every unreached declaration explained), `unreachable` (nothing reachable is left
uncovered; the reasons are in `exclusions.csv`), `flag-gated`.

## Commands

Note: `build/test/test` takes `--filter <Name>`; the `TEST_FILTER` environment variable only works through the cmake targets.

```bash
C=/work/compiler/scripts/coverage/cov.py
python3 $C setup                       # once per checkout: npm install, analyzer, elm-instrument
python3 $C baseline                    # full elm-test + E2E under coverage (~30 min); main tree only
python3 $C report                      # coverage by folder (baseline + nothing)
python3 $C report --all-quick --write-tracker
python3 $C report --folder Compiler.MonoOpt --all-quick
python3 $C report --module Compiler.MonoOpt.InlineSimplify --quick build/coverage/quick/<tag>.json
python3 $C quick --root <dir> [--filter "coverage run"] [--workers 4] [--e2e /work/test/<suite>/src/X.elm ...] --report --module M
python3 $C workspace <name>            # /tmp/eco-cov-agents/<name>/compiler
python3 $C diff <name>
```

How it works:

- `quick` instruments `<root>/src`, runs `elm-test-rs --filter "coverage run"` in
  `<root>/.coverage/instrumented` (about 25 s), and stores the counts. With `--e2e` it also builds a
  `guida.js` from the same instrumented sources and compiles the given E2E test files with it
  (compile only, no JIT run).
- `report` adds the baseline counts and the counts of the quick files it is given. A module's
  baseline counts are used only while its source is unchanged (sha1 at baseline time); a module
  edited since then is measured by quick runs alone, and the report says so. Rerun `baseline` after
  compiler source changes.
- `baseline` runs the whole elm-test suite under coverage, builds the instrumented `guida.js`, moves
  `build/test/*/eco-stuff` aside so that every E2E program is recompiled, and runs `build/test/test`
  with `GUIDA_JS_PATH` set. Package caches in `~/.eco` are kept: package modules are not recompiled.

## E2E against elm-test (2026-11-05)

A second measure compares the suites instead of combining them: what elm-test reaches that E2E
(JIT and JS target) does not, over all of `compiler/src`, so that the E2E programs alone exercise
the compiler as far as the unit tests do (and can serve as a compiler-independent Elm test suite).

```bash
python3 $C gap [--scope] [--kind branches|decls|all] [--folder F | --module M] --all-quick
python3 $C html                        # build/coverage/html/{elm-test,e2e}/.coverage/coverage.html
```

`gap` uses the baseline's elm-test counts and the E2E counts of the baseline plus quick `--e2e` /
`--e2e-js` files. The baseline's E2E side now includes the JS-target suite (`run-js-e2e.js`).

E2E directives added for it (`test/CheckPatterns.hpp`):
- `-- COMPILE-ERROR: <what>`: the program must be rejected; CHECK lines match the error report
  (in `test/elm-compile-errors`, only its title).
  Suite `test/elm-compile-errors/` (type, canonicalization, pattern, main, parse and
  monomorphization errors, mined from the SourceIR rejection catalogue and report tests).
- `-- TEXT-MLIR: <why>`: compiled with `--text-mlir`, which keeps `Mlir.Pretty` covered.
- `-- DIVERGENCE: <how Elm behaves>`: on every test of `test/eco-divergence/`, the suite that
  holds every program whose behaviour differs between eco and Elm (eco's behaviour as CHECK
  lines), run only by the native harnesses. `test/scripts/run-elm-e2e.js` compiles the other
  plain-Elm suites with stock Elm 0.19.x and leaves this one out. Every other plain-Elm suite, including
  `test/elm-conformance`, passes under both eco and Elm 0.19.1.

Programs mined from elm-test (SourceIR catalogue and unit-test pipelines, printed with
`Common.Format`) were kept only when they reached code E2E did not; their CHECK lines are Elm
0.19.1's output for them, so they hold on both compilers.

Result: branches, elm-test 60.2%, E2E 58.9% -> 66.5% (elm-test-only branches 2,282 -> 996);
declarations, elm-test 65.4%, E2E 82.4%. What is left is mostly code that only programs calling
`Elm.Kernel.*` directly reach (kernel ABI instance names, PostSolve kernel typing, bytes-fusion
kernel reads/writes), which user code cannot write, plus test-only helpers (debug printers,
census and validation).

## Where new tests go

A new test reaches the coverage measure in one of three ways; pick the cheapest that reaches the
target code.

1. **A SourceIR case** (`compiler/tests/SourceIR/*Cases.elm`), in the standard catalogue
   (`SourceIR/Suite/StandardTestSuites.elm`). `TestLogic.TypedPipelineTest` runs every catalogue
   program through the whole default pipeline under the label "coverage run". Programs are built
   with `Compiler.AST.SourceBuilder`, define `testValue`, and compile against the 18 mock interfaces
   of `Compiler.Elm.Interface.Basic.testIfaces`, not real packages. New coverage cases go in **new**
   modules named `SourceIR/Cov<Area>Cases.elm` (e.g. `CovMonoOptInlineCases`), added to
   `StandardTestSuites`, so that parallel agents never edit the same file.
   Every catalogue program is also run by the other suites that use `StandardTestSuites`
   (`IdAssignmentTest` and others), so a new case must pass those too.
2. **A unit test** for what a catalogue program cannot express, such as rendering a type error
   report or an inline program that breaks an invariant suite. It goes under
   `compiler/tests/<folder>/`, where `<folder>` is the exact `compiler/src/` folder of the module it
   tests, named `<Module>Test` (or `<Module><Behaviour>Test` when that name is taken; a test of
   several modules is named after what it tests). `compiler/tests/TestLogic/` holds only pipelines
   that run the `SourceIR` cases, and their checkers. The `Test.describe` label must contain
   `coverage run`, so that the default quick filter runs it.
3. **An E2E test** (`/work/test/<suite>/src/<Name>Test.elm`, with `-- CHECK:` lines) for code that
   needs real packages or kernels: `Json`, `Bytes` fusion, `Http`, ports. Measure it with
   `quick --e2e`. To run it for real, `build/test/test --filter <Name>` under
   `flock /tmp/eco-cov-e2e.lock` (test binaries of one tree run one at a time).

Test validity: a program must pass canonicalization, type checking and PostSolve (an "Invalid test
case (frontend failure)" means the test is wrong, not the compiler), except programs that are meant
to fail type checking, for the type error reporting work.

## Bugs found by the loop

`expectCoverageRun` fails when monomorphization, global optimization or MLIR generation returns an
`Err`. A program that makes the backend fail, or that hits crash code, is a compiler bug (record
Elm's own behaviour with `node`/stock Elm when the semantics are in doubt). Follow the
expose-first rule:

1. Keep the case, wrapped with `Compiler.BulkCheck.expectFailure "F<n>: <summary>"` so the suite
   stays green; it reports XPASS once the bug is fixed. A case that **crashes** (Debug.todo) cannot be
   wrapped: leave it out of the case list, keep its builder in the file with a `-- F<n>` comment.
   An E2E reproduction uses the E2E XFAIL marker.
2. Add a row to `compiler/coverage/findings.csv`.
3. Fixing is a separate step, in `/work/compiler/src`, one bug at a time, following
   `design_docs/invariants.csv`; the fix removes the `expectFailure`.

`bulkCheck` stops at a module's first failing case, so an unwrapped failure hides the coverage of
every case after it. Wrap failures before measuring.

## The work loop (one module)

1. `report --module M` (with your quick file) lists M's unreached branches and declarations,
   grouped by declaration, with the source of each.
2. Read the code. For each gap decide: reachable by default Elm input; reachable only under a
   non-default flag (exclude, `flag`); or unreachable (exclude, `unreachable`, with the reason —
   for example a branch the type checker rules out, or a case the previous pass never produces;
   cite the code that guarantees it). Crash code is excluded already.
3. Write tests that reach the reachable gaps (see "Where new tests go").
4. `quick --report --module M`. Keep a test only if it reached something new; otherwise rework it.
5. Repeat until M has ≥ 95% of reachable branches and every unreached declaration is explained,
   then set M's tracker status to `done` (or `unreachable`) with a short note.

Work through modules in pipeline order inside a folder: the shapes that cover an earlier pass
often cover later ones too.

## Running the loop with parallel agents

- Agents work on disjoint folders, each in its own workspace (`cov.py workspace <name>`), with
  `--workers 4` (a quick run peaks near 4 GB; at most three agents on this 15 GB machine). They edit
  only their workspace's `tests/`, new E2E files, and rows of their own modules in
  `tracker.csv`/`exclusions.csv`/`findings.csv`, whose edits they report back, not apply.
- Agents do not edit `compiler/src`. Bugs are recorded (above) and fixed by the coordinator.
- The coordinator merges each workspace (`cov.py diff`), runs the full elm-test suite once
  (`cmake --build build --target elm-tests`), updates the tracker (`report --all-quick
  --write-tracker`), and reruns `baseline` after compiler fixes.
- Temporary files go under `/tmp` only.

## Results log

| Date | Event | In-scope branches |
|---|---|---|
| 2026-11-03 | Baseline (elm-test 14,577 pass, E2E 2,585 pass) | 8,119 / 11,886 (68.3%) |
| 2026-11-04 | Round 1-3 merges (type, mono agents); 1,400+ exclusions added (flag-gated census/inliner code, proven-unreachable arms); 6 findings | 8,827 / 10,457 (84.4%) |
| 2026-11-04 | Fixed lost counts (elm-test-rs terminates workers before their timer flush; fake-elm now flushes before each result message); elm-test baseline re-run, 15,571 pass | baseline alone 8,524 / 10,457 (81.5%) |
| 2026-11-04 | Bug-fix phase: F1-F13 found by the loop all fixed (PostSolve kernel types, aliased lambda types, port unit encoder, number destructuring, polymorphic recursion overflow + prompt error, shader Err, accessor placeholders in tail calls, tail-loop mutual recursion SSA, join staging, papExtend stage peeling, bytes-fusion andThen); each validated by full elm-test + full JIT E2E | — |
| 2026-11-04 | Full re-baseline after the fixes (elm-test 16,236 pass, E2E 2,590 pass); post-F8 accessor-placeholder arms excluded; tracker 46 done, 14 unreachable, 26 flag-gated, 26 open | 8,769 / 9,671 (90.7%) |
| 2026-11-05 | E2E-vs-elm-test gap: 221 compile-error tests (`test/elm-compile-errors/`), 107 mined run tests, 5 TEXT-MLIR tests; JS E2E counted in the baseline; F16, F17 found | (whole compiler) E2E 66.5% of branches, elm-test 60.2% |
| 2026-11-04 | GenerateMlir part A/B rounds merged (type, backend agents), 17 disproven post-F8 exclusions removed, dead code deleted (Mlir.Pretty symbol walk, InlineSimplify inlineVar family); full re-baseline (elm-test 16,745 pass, E2E 2,590 pass); tracker 57 done, 15 unreachable, 26 flag-gated, 14 open | 8,937 / 9,491 (94.2%) |
| 2026-11-04 | Round 4 (solver guards; codegen via real-package E2E tests CovBackend*Test): +~30 branches, 69 proven exclusions; F14 (duplicate SpecIds for one key, fixed by Solver.Monomorphize.mergeConvergedSpecs) and F15 (OperandTypeConsistency checker ignored region scoping; codegen was right) fixed; full re-baseline (elm-test 16,850 pass, E2E 2,594 pass); tracker 62 done, 15 unreachable, 26 flag-gated, 9 open | 8,963 / 9,428 (95.1%) |
