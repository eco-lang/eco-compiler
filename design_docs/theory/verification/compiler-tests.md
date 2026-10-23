# Compiler Tests

The Elm-written compiler is tested by compiling one shared corpus of small Elm programs through a single test pipeline, which calls the same whole-program steps that `eco make` calls, and then running one checker per numbered invariant over the intermediate forms each phase produces. A checker reads a syntax tree, a typed graph or the generated MLIR and fails on any place that breaks its rule. It never runs the program. Every checker runs over every program in the corpus, so a program written to test one rule is checked against all of them. The suite runs under elm-test-rs, an Elm test runner, on the JavaScript build of the compiler, so it needs no native toolchain. Plain unit tests beside it cover the parsers, encoders and data structures that the pipeline relies on.

## Programs and rules are multiplied together

Compiler bugs seldom show up in the program someone wrote to test a rule. They show up when a program shape meets a phase that nobody wrote an example for: a record accessor passed as an argument reaching MLIR generation, or a deeply nested `let` inside a case branch reaching monomorphization. Each invariant belongs to one phase, but the programs that might break it do not. So the corpus and the checkers are kept apart, and every pairing of the two runs. The corpus grows by language shape, the checkers grow by rule, and neither has to know about the other.

The wide-object checkers show how this pays off. Three separate checkers cover a constructor's bitmap of unboxed fields, the consistency of its layout, and the types its destructors project. Each reaches every corpus program the moment it is registered, without anyone writing a program for it.

## The corpus

A corpus program is an Elm module built as a syntax tree, not written as text. A small builder library constructs the tree. There are two reasons. The first phases under test, the canonicalizer and the type checker, consume the tree directly. And a builder lets one case module generate a family of related programs from parameters, which source text cannot do without a template language.

The programs are grouped into case modules by language shape (lets, cases, records, closures and so on), under `compiler/tests/SourceIR/`. Each case module takes an expectation from its caller and applies it to every program it builds. A standard suite list (`StandardTestSuites.expectSuite`) applies one expectation to all the ordinary case modules at once. That list is what a checker hands its check to, and it is the one place where case modules are registered.

Every corpus program defines a value named `testValue`, which is the value under test. The test pipeline adds an entry point that displays it, which is what keeps the program from being pruned away before the late phases see it.

Two case modules are fuzz tests, and they vary only the structure of programs. One generates record accessor shapes and one generates nested patterns, both from a generator that produces well-typed expressions of a requested type. Leaf values are not fuzzed: the compiler treats the literal `42` and the literal `7` the same way, so random numbers add run time and reach no code a single value does not. Fuzzing whole syntax trees is also left out, because it adds little coverage for its cost; the two focused fuzzers take its place.

A few case modules sit outside the standard list, because the standard expectation assumes a source module that compiles. Some start from modules that are already canonical, to test foreign and kernel code. Others must fail type checking, and their tests require the actual type error.

## One pipeline, and it is the production one

The test pipeline reaches the compiler's middle end only through the list of pure whole-program steps (`Compiler.Pipeline.Steps`) that the build itself calls, under the production configuration. This is the rule that makes the suite worth running. A harness that assembles its own pipeline can pick a different monomorphization engine or skip a pass, and then its checkers vouch for code that no user runs and miss bugs in the code they do run. A static script on the test target (`check-test-pipeline-production.sh`) fails the run if the harness imports any compiler pass directly, so the rule cannot be broken unnoticed.

The pipeline lives in one module, `TestLogic.TestPipeline`. It compiles a corpus program as a module of a fixed test package, against hand-written interfaces for a small set of core modules instead of real packages. What differs from a real build is therefore the inputs, not the passes: the interfaces are mocks, the check that pattern matches are exhaustive does not run, and MLIR is generated for one module rather than for a whole application. One module, and not one helper per area, because copies of pipeline setup in separate test files drift apart.

The pipeline has a runner for each stopping point: canonical, typed, typed and optimized, monomorphic, globally optimized, and MLIR. Each runner returns a record of everything produced up to its stop. A checker for a late phase can then read an earlier form too, for example to compare an MLIR layout with the type it came from.

From typed optimization onward, the pipeline appends a synthetic `main` that displays `testValue` as text. Monomorphization specializes outward from the program's entry point, and pruning drops whatever the entry point cannot reach. Without that `main`, the program under test would be specialized to nothing and removed.

The order of the steps up to MLIR is short enough to show whole.

```text
runToMlir src:
  typedOpt  = runToTypedOpt src        -- canonicalize, type check, typed optimize,
                                       -- then add the synthetic main
  prepared  = Steps.prepare cfg globalGraph
  assigned  = (Steps.preMono cfg prepared).assigned -- skipped by the NoPreMono runners
  mono      = Steps.monomorphize cfg globalTypeEnv assigned
  Steps.checkStageArity mono; Steps.checkLayout cfg mono
  simplified = Steps.prune cfg (Steps.inline cfg mono)
  optimized = Steps.globalOpt cfg simplified
  Steps.checkStageArity optimized; Steps.checkClosureStaging cfg optimized
  MLIR.generateMlirModule cfg (Mode.Dev Nothing) optimized
```

Simplified from `compiler/tests/TestLogic/TestPipeline.elm` (`runToMlir` and the runners it calls). Every step between typed optimization and MLIR generation is a call into `Steps`, the same calls the build makes, in the same order. The `check` steps are consistency checks that the build runs at the same points, some only when validation is configured. A runner variant differs only in the configuration `cfg` it passes.

Two such variants exist. The `Stage5` runners use the substitution engine, a second monomorphization engine that the fifth bootstrap stage compiles with; the default engine reuses the type checker's unifier. These runners do not break the production rule, because a real build runs that engine, and they reach it only through `Steps` with a different configuration. The `NoPreMono` runners skip the rewrites that run before monomorphization. No user build does that, so a test that uses one must say in its comment why it needs to.

## The checkers

Each checker is a pair of modules. The first holds the check: a function from a corpus program to a pass or a fail, which runs the pipeline as far as it needs and inspects the result. The second is a small suite that hands the check to the standard suite list and names the invariant.

```elm
suite : Test
suite =
    Test.describe "CGEN_029: Case Tags Count"
        [ StandardTestSuites.expectSuite expectCaseTagsCount "passes case tags count invariant"
        ]
...
expectCaseTagsCount : Src.Module -> Expectation
expectCaseTagsCount srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTagsCount mlirModule)
```

From `compiler/tests/TestLogic/Generate/CodeGen/CaseTagsCountTest.elm` (`suite`) and `CaseTagsCount.elm` (`expectCaseTagsCount`). The check takes one program and knows nothing of the corpus, so a case module added to the standard list extends every check at once. A program that fails to compile fails the check; it does not count as a pass with nothing to inspect.

The checkers are arranged by the phase they inspect, mirroring the compiler: canonicalization, type checking (including the pass that runs after the constraint solver), local optimization, monomorphization, global optimization, and MLIR generation. The MLIR checkers share a toolkit that walks the generated operations, reads their attributes and collects violations.

A checker tests a rule, not an output. No checker compares MLIR with a golden copy. Each asks a question that must hold for every program, such as whether every SSA name is defined exactly once, or whether a partial application's arity matches its closure. This is how the whole theory treats a phase: it is checked against the numbered rules, not against the phase next to it, so a change to one phase's output that keeps the rules does not break another phase's tests. Each checker cites the invariant numbers it enforces in its module comment, and a companion design note (`design_docs/invariant-test-logic.md`) records the inputs and the oracle for each tested rule.

## Checks that can fail

A checker that inspects nothing is worse than no checker, because it reports success without evidence. A check that looks for kernel calls by name prefixes that never occur in real MLIR, for example, finds no call to inspect and passes every program. Bugs go unnoticed under a check like that, so making a vacuous check able to fail tends to expose real compiler bugs. The suite therefore keeps three rules. A test that expects a rejection requires the actual error rather than any failure. A fixture builds what its label says. And each test module's comment states what the test does not establish, so a gap is visible to the next reader instead of hidden behind a green run.

A bug that is found but not yet fixed is pinned by a test that fails for the stated reason. The failing test keeps the bug in view without anyone having to remember it, and it is removed when the fix lands.

## Keeping the suite within memory

One elm-test-rs test per program per invariant would mean tens of thousands of test nodes (about 700 programs and 57 checkers), and that exhausts the runner's memory. So a bulk check folds the programs of one case module into one test node. It stops at the first failing program and reports that program's label, so a failure still names the exact case. The cost is that one run shows only the first failure per case module and checker.

The same pressure is why the corpus has no primitive fuzzing and no trivial variations of one program: each extra program is multiplied by every checker.

## Unit tests and coverage

Some parts of the compiler have a contract that can be stated without compiling a program, and those get plain unit tests, each at the test path of the module it checks. They fall into four groups.

1. Front-end pieces: the parser, the constraint generator, and a golden test of the constraints it produces.
2. Data and encodings: the compiler's own data structures, the type and string tables, round trips of the binary encoders, and the variable-length integer codec.
3. Optimizer analyses: the lambda-set specialization helpers, and the borrow analysis's lifetime lattice, which is compared with a brute-force model that computes the same answer the slow, obvious way.
4. Whole modules and deep input: a test that compiles the real array modules from the core library, and stack-safety tests that feed the compiler deeply nested lets so its own recursion cannot overflow.

Coverage is measured with a fork of an Elm coverage tool, adapted to elm-test-rs, which instruments the compiler's sources and reports which expressions ran. One test runs the whole corpus through the full pipeline and is the driver for coverage runs. The fork's own design note says its output is a picture, not a score. Its job is to show which compiler code no corpus program reaches, so that the corpus grows toward it. No build target runs it.

## Running the suite

The `elm-tests` target first runs the static script that keeps the harness on the production steps, then runs elm-test-rs on a shadow project in the build tree (`build/compiler/build-xhr`). The shadow links the compiler's own sources, the variant sources of its JavaScript build, and the tests. The suite runs on the JavaScript build because that build compiles with stock Elm: the tests then need only Elm, Node and the pinned elm-test-rs, and they can run before, and independently of, the native chain. Continuous integration runs this target on all three platforms.

## Examples of changes that fit the theory
A change fits when it adds a program shape to the corpus or a rule to the checkers and lets the pairing do the rest.

- An added invariant gets a checker module exposing one expectation, a suite module that hands it to the standard suite list, an entry in the invariant-test design note, and a row in the catalog naming the test. It then runs over the whole corpus.
- Another language shape gets a case module and one entry in the standard suite list. Every existing checker applies to it from then on.
- An added whole-program step or configuration switch gets a runner in the test pipeline that calls it through `Steps`, with its own record of forms, so the tests follow the build.
- A known unfixed bug gets a fail-first pin whose message states the reason, removed together with the fix.
- A small isolated unit, such as a codec or a table, gets a plain unit test at the module's test path, as the variable-length integer codec and the type table have.

## Examples of changes that would break the theory
A change breaks the theory when it makes a check quieter or opens a second way into the compiler.

- Calling a compiler pass directly from the test pipeline or the package-compilation test. The tests would then follow a sequence the build does not, and the static script fails the run. Add the call to `Steps` instead.
- Writing a private pipeline inside a checker. It drifts from the build the moment either changes. Use a pipeline runner, or add one.
- A checker that passes when it finds nothing to inspect. It reports success without evidence. Make it fail when its premise is absent, or state the gap in its comment.
- Adding per-value fuzzing or one test per program. Both multiply by every checker and exhaust the runner's memory without reaching any code the corpus does not. Add a corpus program and let the bulk check carry it.
- Loosening an expectation so that a corpus program passes. Either the program, the compiler or the rule is wrong; fix the one that is, or pin the bug.
- Keeping a test for a removed engine or feature switch. It tests code no build runs. Delete it with the code it exercised.

## References

Parent: [verification.md](verification.md).

- `compiler/tests/TestLogic/TestPipeline.elm`: the test pipeline, its runners and artifact records. Read the module comment first.
- `compiler/tests/SourceIR/Suite/StandardTestSuites.elm` (`expectSuite`), then a case module such as `compiler/tests/SourceIR/LetCases.elm`.
- `compiler/tests/SourceIR/Fuzz/TypedExpr.elm`, `AccessorFuzzCases.elm`, `PatternComplexityFuzzCases.elm`: the structural fuzzers. `ForeignCases`, `KernelCases`, `TypeCheckFailsCases`: case modules outside the standard list.
- `Compiler.AST.SourceBuilder`; `Compiler.Elm.Interface.Basic` (`testIfaces`): the tree builder and the mock interfaces.
- `compiler/src/Compiler/Pipeline/Steps.elm`: the shared whole-program steps and their `check` functions.
- `compiler/tests/TestLogic/<Phase>/X.elm` and `XTest.elm`: checker pairs, for example `TestLogic/Generate/CodeGen/SsaUniqueness.elm` and `SsaUniquenessTest.elm`. `TestLogic/Generate/CodeGen/Invariants.elm`: the MLIR checker toolkit.
- `compiler/tests/Compiler/BulkCheck.elm`: the bulk check.
- `compiler/tests/Compiler/PackageCompilation.elm`: compiles the core library's array modules.
- `compiler/tests/TestLogic/TypedPipelineTest.elm`: the coverage driver. Its module comment says errors after typed optimization count as passes; the code fails on them.
- `test/scripts/check-test-pipeline-production.sh`: the script that keeps the harness on `Steps`.
- `compiler/CMakeLists.txt` (target `elm-tests`), `compiler/cmake/toolchain.cmake` (the pinned elm-test-rs).
- `design_docs/invariants.csv`, `design_docs/invariant-test-logic.md`: the catalog, and the inputs and oracle of each tested rule. The design note names some test modules that do not exist in `compiler/tests`.
- `compiler/elm-coverage/THEORY.md`, `guides/test-coverage-howto.md`: the coverage fork. The guide's setup steps assume a toolchain layout the build does not use.
- `docs/testing.md`: how to run the tests. It calls `elm-tests` the front-end tests, but the suite covers every phase through MLIR generation.
