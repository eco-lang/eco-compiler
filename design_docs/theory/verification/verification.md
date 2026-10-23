# Verification

Eco knows it is correct by giving each class of bug the cheapest check that can catch it. The compiler's intermediate forms are checked structurally against the numbered invariants, without running any program. Whole Elm programs carry their expected output in their own source and run on the JIT and AOT paths, the system library's programs on JavaScript too, and the bootstrap compilers must agree with each other byte for byte. Hand-written MLIR files pin each lowering pass to expected text. The runtime has unit tests and property tests over generated heaps. The collector's concurrency is described in formal models that a model checker explores exhaustively, and a build step warns when the code a model describes changes. Every one of these layers serves the invariants catalog: a test exists to move an invariant from written down to tested or enforced.

## Each bug class meets its cheapest check

A bug is cheapest to find with the check closest to where it was made. A compiler phase that breaks its contract can still produce a program that prints the right answer, so a test that looks only at output never sees the break, while a test that walks the phase's output sees it at once. A wrong lowering of one operation hides among the hundreds of operations a real program uses, but a ten-line MLIR file shows it directly. A race between collector threads may show up once in millions of runs, and only a model checker that tries every interleaving at small sizes reliably reaches it. So each class of bug gets its own kind of check, with its own oracle (the thing that decides whether a result is right), and no layer tries to catch everything.

The layers share as much machinery as they can. One corpus of Elm programs feeds several runners. One parser reads the expected-output lines for every runner that uses them. One harness runs each case in its own child process. A fix to the shared machinery reaches every layer, and when two runners disagree on the same source, the disagreement is itself a bug report.

## What each layer catches and misses

When a developer decides where a test belongs, the question is what each layer can see. The table compares the six layers on that.

| Layer | Catches | Misses |
|---|---|---|
| Compiler invariant tests | A broken intermediate form, at the phase that broke it | Anything about the running program; details of the MLIR text |
| Whole-program tests | Wrong output, crashes, collector bugs under real code | Invariant violations that happen to give the right output; rare thread schedules |
| Agreement between runners and stages | Divergence between back ends or bootstrap stages; nondeterminism | Bugs that every stage shares identically |
| MLIR and lowering tests | A wrong lowering of one operation or pattern; gaps in the dialect's verifiers | Whether the compiler emits that MLIR for real programs |
| Runtime unit and property tests | Allocator and kernel logic on generated heaps | Interleavings of concurrent threads |
| Formal models and race tools | Protocol-level races at small sizes | Bugs outside the modeled code; drift in files the canary does not pin |

Most of these tests are compiled by the compiler they check. A bug present in every stage of the compiler can therefore pass every other layer, which is why agreement between the bootstrap stages counts as a layer of its own.

## The five suites

Five suites hold the tests. They run from the compiler's own forms, out to whole programs, then down through the back end to the runtime and its threads. Each has its own document. Agreement between runners, the static scripts and the shared harness belong to no single suite.

### The compiler

The Elm-written compiler is tested by running one shared corpus of small Elm source programs through a single pipeline driver, which compiles them the way `eco make` does, and applying one checker per invariant to the intermediate forms. The tests run under elm-test-rs, an Elm test runner, on the JavaScript build of the compiler, so they need no native toolchain. A small set of unit tests covers the encoders, parsers and data structures the pipeline relies on. See [compiler-tests.md](compiler-tests.md).

The checkers walk the canonical syntax tree, the typed optimized graph, the monomorphic graph, the output of global optimization and the Elm-side MLIR syntax tree. They never run the program, because each phase has a contract and a violation can leave every program's output unchanged for a long time. Walking the form finds the violation in the phase that caused it.

The driver reaches the compiler only through the same list of whole-program steps that the build uses. A test pipeline of its own can choose a different engine or skip passes, and then tests pass on a configuration no user runs. A static script fails `elm-tests` if the test harness calls the compiler any other way.

### Whole programs

Whole Elm programs are checked by compiling each one to MLIR with the real compiler, running it in its own freshly spawned process, and matching its output (and for system programs its exit status) against expected-output lines written in the program's own source. The same corpus is reused by several runners that differ in what they prove: the JIT runner for behavior, the stress runner for long runs under the collector, the JavaScript and AOT runners for agreement between back ends, and the conformance scripts for compliance with third-party protocols. See [program-tests.md](program-tests.md).

Printed output is the oracle because a whole program's correct behavior is a short, known list of lines. A test program prints values with `Debug.log` and states what it expects in comments that begin `-- CHECK:` or `-- CHECK-NOT:`. No reference implementation is needed, and the same file runs unchanged on every back end. Elm's own formatting of logged values is part of the oracle, so a change to that formatting changes what every test expects.

### MLIR and lowering

Codegen tests are small hand-written MLIR files, one property each, that feed eco-dialect or byte-fusion-dialect MLIR straight into the back end or the in-process JIT and assert on the output text with `CHECK` lines in the style of LLVM's FileCheck. The byte-fusion dialect is the one behind fused encoding and decoding of Elm's `Bytes`. These tests pin the lowering passes and the verifier rules, including the ones the Elm front end never exercises, such as limits, rejections and malformed input, without needing the Elm compiler. See [codegen-tests.md](codegen-tests.md).

The files run through a C++ driver inside the test executable, not through a script. A standalone script that pipes MLIR through external tools cannot work here: its separate JIT cannot resolve the runtime's accessor functions, it scores expected failures and negative tests wrongly, and it needs tools from outside the build. Tests that must be rejected are marked in the file and scored by the driver. A file marked as an expected failure is skipped, because the driver has no mode in which a test runs and is expected to fail.

### The runtime

The runtime is tested in layers, each aimed at what the layer above cannot see. Property tests run the real heap on the production nursery. Standalone harnesses run the real allocator under ThreadSanitizer, which detects data races. GenMC, a model checker for C and C++ under weak memory ordering, checks the memory orders the code uses. Guard tests pin every known concurrency defect. The formal models are the specification these layers check the code against, and platform tests cover the process-wide services in spawned child processes. See [runtime-tests.md](runtime-tests.md).

The runtime's unit tests are linked into the same executable as the codegen tests and the whole-program JIT tests, because the allocator is a single object per process. The unit tests and the JIT tests then run against the same allocator, and its statistics accumulate across both. A debug-only heap validator walks the heap during these runs to catch corruption close to its cause.

### The collector's concurrency

The formal models are the collector's concurrency rules in a form a model checker can run. Small TLA+ models, one per concurrent protocol, cover marking, moving objects, and the threads and memory beneath both, and a model checker explores each one exhaustively at small sizes. Weak-memory drivers, checks of traces from real runs against the models, and a hash canary tie the models to the C++. The models do not prove the C++ correct. They find design bugs early, and the canary reports when the code they describe changes. See [concurrency-models.md](concurrency-models.md).

Ordinary tests cannot reach the interleavings that cause collector races, because those are rare schedules that a test run almost never produces. A model explores all of them at small sizes. Each model comes with deliberately broken variants, called mutants, that the checker must reject, which shows the model is able to fail at all.

The canary is a build step that compares hashes of the allocator source files against the pins recorded beside the models. A mismatch is a warning by default, and a build setting turns it into a build failure. Either way, a mismatch means the developer reads the model it names and brings model and code back into agreement before touching the hash.

When a concurrency defect is found, it goes into a register and gets a guard that replays it. While the defect is open, the guard is an expected failure, and an expected failure that starts passing fails the run. Once the defect is fixed, the guard becomes a regression guard, so every known defect stays pinned after its fix.

## Agreement between runners and stages

Several executions of one corpus form a layer of their own, and their oracle is agreement. The JIT runner, the AOT runner, the JavaScript runner and the bootstrap compilers all consume the same Elm sources, so any difference between them is a bug, found without anyone writing down the right answer. The equivalence check compiles every whole-program test source twice, once with the JavaScript build of the compiler from the second bootstrap stage and once with the native build from the sixth, and compares the binary MLIR byte for byte. The bootstrap adds fixed points: a compiler that rebuilds itself must produce identical output, for both the JavaScript and the native compiler.

Two gates put these checks early in the bootstrap. The JIT gate runs the whole-program tests right after the first stage is built. The AOT gate runs them after the JavaScript compiler reaches its fixed point, compiling each program to a native executable. Run in that documented order, a back-end regression is pinned to the stages before the gate that caught it and is reported before the slow self-compiles begin. The gates are separate targets, not dependencies of the chain: the aggregate bootstrap target does not run them, and continuous integration runs the AOT gate after the whole bootstrap.

## Cheap scripts before the build

A few scripts search the source for one structural rule each and run before anything is built. They check that code which pushes collector roots does so a bounded number of times, that large objects are reached only through accessor functions, and that kernel source files sit in the right libraries. A search cannot prove a rule, but it catches the common way of breaking one in seconds. The script that keeps the compiler tests on the production steps belongs to the same family and runs with `elm-tests`.

## One harness for every runner

Three pieces of test machinery are shared across layers.

The first is the parser for `CHECK` directives, used by the codegen tests, the byte-fusion tests and both the JIT and AOT whole-program runners. An unknown directive variant is a parse error. If the parser skipped unknown variants, a fixture with a misspelled directive would pass while asserting nothing, and a check that cannot fail is worse than none. For the same reason, a marker that restricts a test to Linux or keeps it off the AOT path must state its reason.

The second is the isolated-child runner. Every case runs in its own child process, so a crash, a JIT failure or a corrupted heap fails one case instead of the whole run. The children are spawned, never forked, because a fork copies a live heap, the collector's threads and the runtime's global state into the child.

The third is the build-tree shadow. Each package test directory gets a copy in the build tree, and both the JIT and AOT runners compile from it, so the compiler's caches stay out of the source tree.

## When the checks run

Two everyday targets run the static scripts and then the main test executable, `test/test`. The `check` target rebuilds incrementally and runs only the first two scripts. The `full` target cleans first, so it never tests stale `.mlir` files from an earlier compile, and it is the right choice after any change to Elm code or MLIR generation. `full` is also the bootstrap's JIT gate, and the order of its steps carries the design.

```cmake
add_custom_target(full
    COMMAND python3 ${CMAKE_SOURCE_DIR}/test/scripts/check-root-bounded.py ${CMAKE_SOURCE_DIR}
    ...
    COMMAND sh ${CMAKE_SOURCE_DIR}/test/scripts/check-kernel-homes.sh ${CMAKE_SOURCE_DIR}
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target clean
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test eco-system-core-test eco-system-examples
    COMMAND ${CMAKE_BINARY_DIR}/system-kernel-cpp/eco-system-core-test
    COMMAND sh -c "${CMAKE_BINARY_DIR}/test/test $\${TEST_FILTER:+--filter \"$$TEST_FILTER\"}"
    ...
    ${_full_js_e2e}
```

Source: root `CMakeLists.txt`, target `full`, trimmed. The source searches come before any build, so a rule violation fails in seconds. The `clean` step is what keeps stale MLIR out. Every runner comes after the rebuild, so each one tests output of the same fresh compile, and a further runner belongs after the build steps too.

The stress tests are a separate executable. The AOT runner, the equivalence check, the model checks, the GenMC checks and the full defect-guard run are separate targets that a developer runs on purpose; only the unit defect guards run inside the main test executable. The JavaScript runner for the `eco/system` suite is a target of its own too, and `full` also runs it as its last step.

Continuous integration covers the three platforms differently:

| Platform | What CI runs |
|---|---|
| Linux | `full`, `elm-tests` and the stress tests, then the bootstrap and the AOT runner |
| macOS | `elm-tests`, the main test executable, then the bootstrap; no stress tests or AOT runner |
| Windows | `elm-tests`, the main test executable, then the bootstrap; the whole-program and codegen suites in the executable report no tests, and the stress, AOT and equivalence runners are not built |

So the whole-program tests establish parity on Linux and macOS but not on Windows, and only Linux runs the stress tests and the AOT runner. Platform-specific cases carry a marker with a reason, never a silent skip.

The model checks, the GenMC checks, the ThreadSanitizer builds, the full defect-guard run and the protocol conformance scripts stay out of continuous integration and are run by the owner. Model checks take hours, and the conformance scripts download their own tools, so neither suits a hosted runner.

## The invariants catalog as the definition of correct

Every layer cites the numbered rules of the invariants catalog by number instead of restating them; [invariants.md](../invariants/invariants.md) describes the catalog, its statuses and how rows link to the checks that cite them.

The dialect's verifiers sit outside every test target. They run when the back end reads MLIR and reject a malformed single operation at the boundary between the Elm and C++ halves. They check only local facts, and checking between lowering passes is off in the production drivers, so facts that span operations, such as call signatures and layouts, are left to the tests above.

## Adding a check

A change fits when it adds a check at the layer whose oracle catches the bug most cheaply, goes through the shared machinery, and cites the invariant it serves. A change breaks the theory when it makes a check quieter without making the code more correct.

### Examples of changes that fit the theory
- An added compiler invariant gets a row in the catalog naming its test module, a checker for it, and registration with the shared corpus, so it runs over every module.
- An added lowering or operation gets a small MLIR file with `CHECK` lines, and an Elm program with `-- CHECK:` lines that reaches it from source. The first pins the lowering; the second pins the compiler's use of it.
- An added kernel package or runtime feature gets its own test package of Elm programs with a thin runner built on the shared whole-program base, registered in the list of test packages. It then runs on every path the corpus runs on. The `elm-core`, `elm-json`, `elm-http` and `eco-system` test packages have this shape.
- A platform-specific case uses the Linux-only or skip-AOT marker with a reason, so the restriction is visible in the file.
- A change to a collector protocol updates the model and the canary's pins together and adds a mutant the model must reject.
- A found concurrency defect gets a register entry and a guard before the fix, so it cannot return unnoticed.

### Examples of changes that would break the theory
- Testing a pass's output through a pipeline of the test's own. Tests then pass on a compile no user runs; extend the shared steps instead.
- Adding a `CHECK` variant or a skip marker that the parser tolerates silently. A misspelling then asserts nothing; make it parse or fail.
- Updating a canary hash without reading the model it names. The hash exists to force that reading, so investigate the model first.
- Adding primitive-value fuzzing or one test per case to the compiler suites. Both cost run time and memory and reach no code the corpus does not.
- Marking a failing test skipped to get a clean run. The failure disappears from view. Only the collector's concurrency defect guards have a real expected-failure mode, in which a guard fails once its defect stops reproducing; the codegen and whole-program harnesses can only skip. Fix the code, or, for a collector defect, add a register entry and a guard.
- Copying the whole-program runner for one package. Fixes to the shared base would then miss it; build on the base instead.
- Running `check` after a change to Elm code or MLIR generation. It can test stale `.mlir` files; use `full`.

## References

Parent: [eco.md](../../../THEORY.md). Children: [compiler-tests.md](compiler-tests.md), [program-tests.md](program-tests.md), [codegen-tests.md](codegen-tests.md), [runtime-tests.md](runtime-tests.md), [concurrency-models.md](concurrency-models.md).

Code and documents:

- `docs/testing.md`: how to run the tests. It omits the AOT, equivalence and JavaScript runners, the static scripts, the model and GenMC checks, the defect guards and the conformance scripts.
- `CMakeLists.txt` (targets `check`, `full`, `stress`, `tla-canary`, `register-guards`) and `test/CMakeLists.txt` (`ELM_TEST_PACKAGES`, the package shadow trees, `run-aot-e2e`, `run-mlir-equivalence`, `run-js-e2e`). The canary's strictness is set by `ECO_TLA_CANARY_STRICT`.
- `test/CheckPatterns.hpp`: the shared `CHECK` directive parser, the `LINUX-ONLY:` and `SKIP-AOT:` markers. `CHECK-DAG` is an alias for `CHECK` there.
- `test/ElmE2ETestBase.hpp`, `test/TestSuite.hpp`, `test/IsolatedTestRunner.hpp`, `test/SpawnedChildren.hpp`: the whole-program base and the isolated-child runner.
- `test/main.cpp`, `test/aot_e2e_main.cpp`, `test/mlir_equivalence_main.cpp`: the JIT, AOT and equivalence runners.
- `compiler/tests/TestLogic/`, `compiler/tests/SourceIR/`: the compiler invariant checkers and their corpus. `Compiler.Pipeline.Steps` is the only way in.
- `test/scripts/`: the static check scripts, including `check-test-pipeline-production.sh`.
- `test/tla/README.md`, `test/tla/manifest.txt`: the formal models and the canary's pins.
- `design_docs/invariants.csv`, `design_docs/invariant-test-logic.md`: the catalog, and the inputs and oracle of tested invariants.
- `docs/bootstrap.md`: the stages, the two gates and the fixed points.
- `.github/workflows/`: continuous integration per platform (`linux-aot.yml`, `win-aot.yml` and the macOS workflow).

Invariants: GC_MODEL_001 (investigate the named model before touching a canary hash); REP_*, CGEN_*, HEAP_*, MONO_*, GOPT_*, FORBID_* (the families the layers check).
