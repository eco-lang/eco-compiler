# Whole-Program Tests

Whole Elm programs are checked by compiling each one to MLIR with the real compiler, running it in its own freshly spawned process, and matching what it prints against expected-output lines written as comments in the program's own source; for programs that use the system library, the exit status is checked too. A test is an Elm program with a `main` and those comments, and needs no C++ of its own. One corpus of such programs is reused by several runners that differ in what a pass proves: the JIT runner checks behavior, the stress runner keeps programs running for a long time under the collector, the JavaScript and AOT runners check that the back ends agree, and the conformance scripts check the network protocols against third-party test suites.

## The program carries its own oracle

The compiler, the runtime and the kernels only mean something together. The representation rules, such as which values are stored unboxed in a closure, are broken at the boundary between the code generator and the runtime, and that boundary is exercised only when a real program runs. The cheapest faithful check is therefore to compile a program, run it, and read what it logs. A program logs values with `Debug.log`, and comments starting `-- CHECK:` list the lines it must print. Because the expectation lives in the file, the file describes itself, and every runner can reuse it unchanged.

Many tests pin one miscompile. Its header names the bug and the rule it broke, and its directives state the right output.

```elm
module LocalRecCaptureBoolTest exposing (main)

{-| A let-bound local RECURSIVE function captures a Bool computed in the same
`let`. ...

    'eco.papCreate' op captured Bool (i1) at index 0 violates REP_CLOSURE_001
...
-}

-- CHECK: count_true: 3
-- CHECK: count_false: 4
...
main =
    let
        _ =
            Debug.log "count_true" (count 1)

        _ =
            Debug.log "count_false" (count 5)
    in
    text "done"
```

From `test/elm/src/LocalRecCaptureBoolTest.elm`. The file is the whole test: nothing in C++ names it, and each runner discovers it by its directory. With the bug present, lowering rejects the program with the quoted error; with it fixed, the program must print both counts.

There is no assertion library for values. Every expectation is text, so it must come from `Debug.log` or from what the program writes to its output streams. Elm's own formatting of logged values is part of the oracle, so a change to that formatting changes what every test expects.

## What the directives say

Directives are comments at the start of a line. They fall into three groups by what they constrain.

1. Output directives say which lines must appear and which must not. They borrow LLVM's FileCheck syntax, with plain, negative, unordered, label, same-line and next-line variants. The unordered and label variants mean only what the plain one means. Matches may come in any order unless a same-line or next-line variant ties one to the match before it. A pattern may hold regular expressions in double braces. One variant matches the program's generated MLIR text instead of its run output, for a test whose point is the code the compiler emits.
2. A flags directive passes JSON to the program as its start-up flags.
3. Process directives describe the program as an operating-system process: the exit status it must return (`-- EXIT:`), text to feed on its standard input (`-- STDIN:`), and markers that restrict a test to Linux or keep it off the JavaScript or AOT path. A restricting marker must state its reason. `-- XFAIL-NATIVE:` marks a test that is expected to fail on the native runners only: a failing run counts as a pass, labelled XFAIL, and a passing run counts as a failure (XPASS), so the mark is removed as soon as the behaviour is fixed. A compile failure is never expected.

One parser in C++ reads all of them, and the JIT runner, the AOT runner and the codegen test hosts share it. An unknown variant is a parse error. If the parser skipped unknown variants, a fixture with a misspelled directive would assert nothing and still pass, and a check that cannot fail is worse than none. The JavaScript runner is a Node script, so it reads the same directive syntax with its own code, and it ignores directives about MLIR text, which it never produces.

## The corpus

The programs are split into packages by what they exercise. Each package is a directory with its own Elm project file, listed once in the test build's package list, which makes a shadow copy of each in the build tree so the compiler's caches stay out of the source tree. Seven kinds of package hold whole programs, ordered from the language outward.

1. The language corpus (`test/elm/`, about 640 programs) is the largest. It covers the core language and code generation: case expressions, closures, partial application, records, tail recursion and representation corner cases. Many of its programs are regression pins like the one above.
2. One suite per standard Elm package (core, bytes, JSON, parser, regex, time, URL, HTTP and HTML) exercises that package's C++ kernel through its public Elm interface. The language corpus does not cover these kernels systematically, so each package gets its own suite.
3. The eco kernel suite tests the internal kernel package: the mutable variables used to synchronize tasks, files, processes, the environment and the collector report.
4. The system suite (`test/eco-system/`) tests Eco's public system library: files, sockets, TLS, child processes, HTTP servers, WebSockets, streams, HTML serialization and program lifetime.
5. The stress suite holds longer programs built on a shared harness module.
6. The conformance package holds scripts and one Elm WebSocket client that third-party protocol suites drive.
7. The Elm conformance package (`test/elm-conformance/`) is unrelated to the one above. It holds stock-elm/core programs whose expectations were recorded from Elm itself on Node (`run-js-e2e.js --record`). The JavaScript runner and the native runners both check them, so they show where Eco's behaviour differs from Elm's. On the JavaScript side, a guard makes any Char equality throw if Elm's debug build and `--optimize` would answer it differently.

Each package's runner is a thin wrapper over one shared base (`ElmE2ETestBase.hpp`), parameterized by name and directory. Copies of a runner of about a thousand lines drift apart, and a fix to one misses the others. With one base, a fix to how programs are compiled or matched reaches every package.

Three directories sit beside the corpus without being part of it. Two hold C++ unit tests, one of the kernel export interfaces and one of the system library's service core, which run without any Elm program. The third holds a single program kept out of the corpus on purpose and used by hand to reproduce a compiler hang on mutually polymorphic recursion.

## Running one program

The JIT runner works in two phases, and the other runners follow the same outline.

In the first phase it compiles, in parallel, every Elm file whose MLIR is older than its source, using the JavaScript build of the compiler under Node; very wide programs get a larger Node stack, so that the compiler's recursion over them does not overflow. Compiling everything first keeps the slow step parallel and lets a run skip files that have not changed.

In the second phase it runs each program on the MLIR JIT inside a freshly spawned child process, under a watchdog that kills a hung test, with a free network port reserved for it. The child writes its result to a mapped file that the parent reads. A fresh process per test keeps crashes, hangs and collector state from leaking between tests or into the harness, and it means the heap configuration under test is the production one.

The children are spawned, never forked from the harness. A fork copies the allocator's process-wide state, its collector threads and LLVM's state into the child. The harness process runs the runtime's unit tests first, and they configure the semi-space nursery. A child forked after them would inherit that nursery instead of the region nursery that production uses, and the everyday gate would test the wrong collector. Fork also does not exist on Windows. So the test binary starts a copy of itself in a child mode, and a guard in the child (`RegionNurseryGuard.hpp`) fails any test that runs on a nursery other than the region nursery unless the test asks for the semi-space one by name. If start-up time ever matters, several programs can be batched inside one spawned child; running them in the harness process brings back every problem of the fork.

## Where the output is matched

Matching happens in one of two places, and the choice follows from what the program can do.

- In output mode, the child matches the output directives against what the Elm runtime logged. The pure packages use it, because their programs only log values.
- In process-output mode, the parent matches after the child exits, against the runtime's log plus the child's raw standard output and standard error, and it checks the exit status. The system suite uses it, and so does any test with an exit directive.

Process-output mode exists because a system program has three effects that matching inside the child cannot see. It writes to file descriptors directly, it may end the process by calling exit, and its exit status is part of what it promises. So the parent checks after the child ends, an exit hook in the child publishes the runtime's log when the program calls exit, and standard input is empty unless the test supplies text. Empty input keeps every run the same and stops a test from waiting on a terminal.

```elm
-- STDIN: abc\n
-- STDIN: def\n
-- CHECK: echo: abc|def|
-- CHECK: chunks > 0: True
-- EXIT: 0
```

From `test/eco-system/src/StdinEchoTest.elm`. The exit directive puts the test in process-output mode. The input lines are joined and fed to the child, and the program must both echo them and exit with status 0.

The HTTP tests need a server, so the harness runs one in-process on ephemeral ports. Its addresses reach the programs through environment variables, read by a checked-in Elm module (`TestServerConfig`). Generating that module with the ports written into it would put a generated file in the shared source tree: two test binaries running at once would overwrite each other's ports, and every run would force the HTTP suites to recompile. Per-run data travels through the environment everywhere in the harness for the same reason.

## The runners

The runners share the corpus and differ in what a pass proves. The table orders them from the everyday gate outward.

| Runner | Runs the programs on | A pass proves | Runs in |
|---|---|---|---|
| JIT runner | The MLIR JIT, one spawned child per program | The compiler and runtime give the expected behavior | `check`, `full`, continuous integration |
| Stress runner | The JIT, with flags for size and duration | The behavior holds under long runs and heavy collection | Its own target; continuous integration on Linux |
| JavaScript runner | The JavaScript back end under Node | The system library behaves the same on both back ends | Its own target, and the last step of `full` |
| AOT runner | Native executables, compiled by the self-built JavaScript compiler and lowered by the native back end | The native pipeline passes what the JIT passes | The bootstrap's AOT gate; continuous integration on Linux |
| MLIR equivalence | No run: the MLIR of two bootstrap stages is compared byte for byte | A rebuilt compiler emits the same programs | On request |
| Conformance scripts | The example echo server and the WebSocket client, on both back ends | The protocols comply with third-party suites | By hand, never in continuous integration |

### Stress

The stress runner is a separate binary because soak-length iteration counts would slow the everyday gate. Its programs read their size, loop count, seed and time limits as start-up flags, not as constants in the source, so a soak can be scaled without editing a program. Every stress program reads the same flags record, because they all need the same handful of parameters, so no general decoder for arbitrary flags is needed.

The shared harness module (`StressHarness.elm`) runs one iteration per update cycle. A wall-clock deadline can then end a soak between iterations, and reaching it counts as a pass. A stress program is usually a scaled-up version of a functional test: round trips of bytes, JSON, dictionaries and lists across many collections, contention on the mutable variables, or file, socket, stream and HTTP load on the system library. Continuous integration runs the stress target on Linux, so it is a regression tier and not an optional extra.

### JavaScript

The JavaScript runner (`test/scripts/run-js-e2e.js`) runs the system suite under Node. The system library promises one Elm interface over two back ends, and running the identical programs with the same directives on both is the check that the wrappers and decoders really are shared. The runner brings a Node twin of the HTTP test server and a stand-in for the browser's request object. The marker that keeps a test off the JavaScript path is for behavior that is genuinely native-only, such as comparing the C++ HTML writer with the Elm reference serializer.

### AOT and MLIR equivalence

The AOT runner compiles each program with the stage-3 compiler, which is the JavaScript compiler after the bootstrap has rebuilt it with itself, and lowers the MLIR to a native executable with the native back end. It is the bootstrap's second gate. Its documented place is right after the JavaScript compiler's fixed-point check, so a back-end regression is caught before the slow self-compiles of the native stages begin, and it is pinned to the stages before the gate. The target itself depends only on the stage-3 compiler and the native back end, not on the fixed-point check, so only that documented order puts it there; continuous integration runs it after the whole bootstrap.

The equivalence check compiles every whole-program test source with the JavaScript build of the second stage and the native build of the sixth, and compares the binary MLIR byte for byte. It runs no program. Any difference is a bug in one of the two compilers, found without anyone writing down the right answer. It is a separate target that a developer runs on purpose.

### Conformance

The conformance scripts download the Autobahn WebSocket test suite and the h2spec HTTP/2 test suite into a temporary directory, build the example echo server and the WebSocket client for both back ends, and run the suites against them. They stay local because the downloads are large and a run takes tens of minutes. Running them in continuous integration or in containers is ruled out by that cost and by the availability of the tools. For h2spec the pass condition is a recorded baseline of passing cases per back end (`h2spec-baseline.txt`), which must not fall, rather than a clean sweep. Mature implementations such as nghttp2 and Node fail some strict cases on purpose, so a clean sweep is not the right target.

## Source guards beside the programs

Some rules are properties of C++ files or source text, which no Elm program can observe, and breaking one causes a miscompile or heap corruption that surfaces far from the edit. Small scripts in `test/scripts/` check them directly. They fall into three groups.

1. Heap discipline: code that pushes collector roots does so a bounded number of times, not in proportion to its input, and large string and byte bodies are reached only through accessor functions.
2. Kernel hygiene: kernel source files sit in the right libraries and their names do not collide, and the licensed kernel files match an audited hash list. The license check runs with every build, and drift fails it.
3. Pins on other parts of the project: the formal models' canary, which warns when the code a model describes changes; the macOS minimum version; and the script that keeps the compiler's test harness on the production steps.

A few other scripts in the directory are one-off tools rather than checks.

## Where the programs run

Continuous integration runs the whole-program suites on Linux and macOS, so parity between those two platforms is tested, not assumed. Every platform also runs the bootstrap, and only Linux runs the stress tests and the AOT runner.

Windows builds and runs the test executable, but the whole-program suites report no tests there: the JIT fails a heap-pointer check on that platform. The HTTP test server is compiled out for lack of OpenSSL, and the stress, AOT and equivalence runners are not built, because their child-process code is POSIX-only. Spawning children rather than forking them is what makes a port possible.

Two test binaries must not run at once from the same build tree, because they share the compiler's caches. Separate build trees can run side by side, since each gets its own server addresses through the environment.

## Examples of changes that fit the theory
A change fits when it adds a program with directives, goes through the shared parser and base, and so reaches every runner that can use it.

- A regression test for a fixed bug is one small program in the language corpus, or in the matching package suite, with one output directive per expectation and a header naming the broken rule. It needs no C++, and it lands with the fix it pins.
- A test package for another Elm package or kernel gets its own directory and project file, a thin wrapper on the shared base, and registration in both the package list and the test binary. The core package suite has this shape.
- A system library capability gets programs in the system suite, with exit and input directives as needed, a stress variant if load matters, and no JavaScript skip unless the behavior is native-only.
- An added directive goes into the shared C++ parser once, which serves the JIT, AOT and codegen hosts. If system programs will use it, the JavaScript runner must read it too: that runner rejects an output variant it does not know, and silently ignores any other directive it does not read. The Linux-only marker and the exit directive have this shape.
- A source-level rule that Elm cannot observe gets a guard script in `test/scripts/`, run by the everyday targets.
- A stress program is written on the shared harness module and reads the shared flags.

## Examples of changes that would break the theory
A change breaks the theory when it moves an expectation out of the program, adds a second dialect of directives, or makes a test pass by asserting less.

- A hand-written C++ test that embeds an Elm expectation. Only the JIT runner would ever see it. Write the program with directives instead.
- A second C++ directive parser, or a dialect that only one runner understands. A fix to one would miss the other. Extend the shared parser.
- Forked children, or programs run inside the harness process, to save start-up time. Both bring back the inherited nursery and leaked state. Batch programs inside one spawned child if speed matters.
- Weakening or deleting a directive to make a test pass. A program that constrains nothing is the failure the strict parser exists to prevent. Fix the code. The program runners have no expected-failure mode, and their skip markers are for behavior a target or host lacks, not for a failure.
- Writing generated files into a package's source directory during a run. Concurrent runs collide and the package recompiles every time. Pass per-run data through the environment.
- Making h2spec or Autobahn a gate by demanding a clean sweep. The baseline records strict cases that mature servers also fail on purpose.
- Adding a package directory without registering it in both the package list and the test binary. The package list creates the shadow trees for the JIT and AOT runners, and the test binary registers the JIT suite; missing either leaves the package silently unrun.

## References

Parent: [verification.md](verification.md).

- `test/CheckPatterns.hpp`: the directive grammar and matching. `CHECK-DAG` and `CHECK-LABEL` are synonyms for `CHECK`, which already matches anywhere in the output.
- `test/ElmE2ETestBase.hpp`: the compile-then-run base, output and process-output modes, stress flags.
- `test/SpawnedChildren.hpp`, `test/IsolatedTestRunner.hpp`, `test/RegionNurseryGuard.hpp`, `test/ChildStdin.hpp`: child-process isolation, the nursery guard and standard input. Some comments in `ChildStdin.hpp` and `test/stress-elm/main.cpp` speak of forked children; the harness spawns them.
- `test/NodeBigStack.hpp`: the larger Node stack for very wide programs.
- `test/CMakeLists.txt` (`ELM_TEST_PACKAGES`, `run-aot-e2e`, `run-mlir-equivalence`, `run-js-e2e`), `test/main.cpp`: the package list, runner targets and suite registration.
- `test/elm/`, `test/elm-core/` and the other `test/elm-*/` packages, `test/eco-kernel/`, `test/eco-system/`: the corpus. `test/eco-system/EcoSystemTest.hpp`: the system suite's runner.
- `test/stress-elm/main.cpp`, `test/stress-elm/StressElmTest.hpp`, `test/stress-elm/src/StressHarness.elm`: the stress binary and harness.
- `test/scripts/run-js-e2e.js`, `test/aot_e2e_main.cpp`, `test/mlir_equivalence_main.cpp`: the JavaScript, AOT and equivalence runners.
- `test/conformance/autobahn.sh`, `test/conformance/h2spec.sh`, `test/conformance/h2spec-baseline.txt`: the conformance scripts and baseline.
- `test/TestServerConfig.hpp`, `test/TestHttpServer.hpp`: the HTTP test server and its addresses (`ECO_TEST_HTTP_URL`, `ECO_TEST_HTTPS_URL`).
- `test/kernel/`, `test/eco-system-core/`: C++ unit tests kept beside the corpus. `test/fixtures/`: the manual hang reproduction.
- `test/scripts/check-root-bounded.py`, `check-large-body-access.sh`, `check-kernel-homes.sh`, `check-kernel-license-manifest.sh`, `check-test-pipeline-production.sh`: the guard scripts.
- `docs/testing.md`: how to run the tests. It omits the system suite's process-output mode, the JavaScript, AOT and equivalence runners, the guard scripts and the conformance scripts.
- `design_docs/all-e2e-test-cases.md`: a catalog of the language corpus that covers only part of its programs.
- Invariants that regression programs cite: REP_CLOSURE_001 (Bool in closures), HEAP_069 (region nursery), HEAP_082 (reset guard).
