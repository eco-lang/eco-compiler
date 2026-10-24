# Codegen Tests

Generated MLIR and the lowering passes are tested with fixtures: small hand-written MLIR files that each pin one property. A fixture goes straight into the back end with no Elm compiler involved, either through the back end's command-line compiler run as a separate process or through the JIT inside the test process. Comment lines in the fixture name the stage at which the back end stops and the text its output must or must not contain, in the style of LLVM's FileCheck tool. There are two sets, each with its own harness: one for the eco dialect and one for the byte-fusion dialect, which implements fused encoding and decoding of Elm's `Bytes`. Because the input is written by hand, a fixture can state inputs the Elm front end never produces, such as objects past the heap's size limits or malformed operations that the dialect's verifier must reject.

## One property, at the stage where it shows

A whole Elm program exercises hundreds of operations at once, so a wrong lowering of one of them can hide behind the others and the program can still print the right answer. A fixture uses a handful of operations, stops the back end at the stage where its property is visible, and checks that property alone. When it fails, the property it names is broken and nothing else is in the way. Each fixture's header comment says which rule or design it pins, so a failure leads straight to the rule.

The second reason for this layer is reach. The front end checks a program before it becomes MLIR, so no Elm source can produce a record one field past the limit, a closure with too many arguments, a deliberately wrong pass decision or an operation with the wrong kind of slot. Hand-written MLIR produces all of these. The whole-program harness has no mode for an expected compile error, so a check that some input is rejected belongs here or in the compiler's own Elm tests.

The cost is that a fixture says nothing about whether the compiler ever emits the MLIR it contains. That is why an added lowering gets both a fixture here and an Elm program that reaches it from source: the fixture pins the lowering, the program pins the compiler's use of it.

## How the fixtures run

Each set's harness finds its fixtures by listing every `.mlir` file in its directory and makes each file one test, named `codegen/<file>` for the eco set and `codegen-bf/<file>` for the byte-fusion set, so a `codegen` filter selects both. The harness runs every `// RUN:` comment line of the fixture in turn, and the fixture passes only if each one does. Every test runs in its own spawned child process, in parallel with the others, so a crash or a corrupted heap fails one fixture and leaves the rest alone. Both sets are suites inside the main test executable rather than separate runners, which is how they share the isolated-child runner and the `CHECK` parser with the whole-program tests. On Windows both suites are built over a directory that does not exist and run nothing.

```
fixture.mlir --(each RUN line: stage, flags, expected exit, check prefixes)--> harness
harness --(plain JIT stage)--> in-process runner --(printed values)--> matcher
harness --(any other line)--> compiler subprocess --(exit status; IR text or diagnostic)--> matcher
matcher --(the line's prefixes' directives from the fixture)--> pass or fail
```

The byte-fusion harness runs each fixture through the eco harness's fixture runner, so both sets follow the same RUN-line, exit-status and matching rules, the same nursery check and the same subprocess routing; only the directory and the test names differ.

## What a fixture looks like

A fixture is one `.mlir` file. Its `// RUN:` comment lines say how to compile it, its `// CHECK` comment lines (or lines under the check prefixes a RUN line names) are the assertions, and everything else is the MLIR input. This one pins that a two-field tuple used only as a value lowers to an LLVM struct and allocates nothing on the heap.

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0 escape-analysis plumbing: eco.make.tuple2 + eco.project.tuple2
// over a value-level tuple lower to LLVM struct insert/extract chains.
// Verify no heap allocation occurs.

module {
  func.func @value_tuple2_swap(%a: i64, %b: i64) -> i64 {
    %t = eco.make.tuple2 %a, %b : (i64, i64) -> !eco.tuple2<i64, i64>
    %x = eco.project.tuple2 %t[1] : !eco.tuple2<i64, i64> -> i64
    ...
  }
}

// CHECK: llvm.func @value_tuple2_swap
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, i64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
// ...
// CHECK-NOT: eco_alloc_tuple2
// CHECK-NOT: eco_resolve_hptr
```

Source: `test/codegen/value_tuple2.mlir`, trimmed.

The property under test, that nothing is allocated, is carried only by the two `CHECK-NOT` lines, each checked against the whole output. The positive lines show the shape the lowering produces instead. The `%ecoc` and `%FileCheck` spelling keeps the file readable as an ordinary LLVM test, and the harness interprets the line as lit would, but it matches the directives itself rather than running FileCheck.

## Choosing the stage

The stage decides what the fixture can see. Some properties exist only as the shape of the IR: that a small aggregate value allocates nothing, that a function is marked as never reaching a collection, that a capacity check is hoisted out of a loop. Those need the IR dumped right after the pass that produces the shape, before later passes rearrange it. Properties about behavior need the program to run. The five stages differ in what output the matcher sees.

| Stage | Output the fixture checks | Typical use |
|---|---|---|
| `jit` | What the program prints when run in process, usually through the dialect's debug-print operation | Arithmetic edge cases, round trips, runtime behavior |
| `mlir` | The module as read, before any pass | Parser and verifier behavior |
| `mlir-eco` | The module after the eco-to-eco passes only | Passes that rewrite eco operations among themselves |
| `mlir-llvm` | The module after lowering to LLVM's dialect; the default when no stage is named | Lowering shape |
| `llvm` | LLVM IR | Attributes and calls that appear only at the end |

JIT fixtures run in the test process through the back end's in-process runner, with the runtime and kernels linked into the test executable. That is how they reach the runtime's accessor functions for tuples and records, which a separately launched JIT cannot resolve. Before running one, the eco harness checks that the heap uses the region nursery, the one production uses, so a fixture cannot pass on an allocator configuration that no compiled program runs with. A JIT fixture that contains a crash operation runs in a subprocess instead, so its crash cannot take the test runner down. The other four stages always run the compiler as a subprocess.

## What counts as an assertion

The harness reads a fixture's RUN lines and directives itself (`test/codegen/CodegenIsolatedTest.hpp`, `test/CheckPatterns.hpp`). It follows lit and FileCheck closely enough that a fixture means what an LLVM developer would read into it; a RUN line or directive it cannot honour is a hard error rather than a silent no-op.

Every RUN line has the form `[not [--crash]] [env NAME=VALUE...] %ecoc %s [-emit=STAGE] [flags...] 2>&1 | %FileCheck %s [--check-prefix=P | --check-prefixes=P,Q]`, and each one runs:

1. the flags after `%s` go to the compiler verbatim, and an `env` prefix sets environment variables for that run;
2. the exit status is checked as lit does: without `not` the compiler must exit 0; `not` requires a non-zero exit and fails on a crash; `not --crash` requires a crash, such as the abort of LLVM's `report_fatal_error` that the back end's internal self-checks use;
3. the output, stdout and stderr together, must satisfy the directives of the line's check prefixes (`CHECK` when none is named). A prefix with no directive in the file is an error, as in FileCheck.

A JIT line with no `not`, `env` or flags, in a fixture without a crash operation, runs in the test process; every other line runs the compiler as a subprocess. A fixture with no RUN line at all (the upstream probes below) must still parse and lower with the compiler's default stage and exit 0.

The directives under a prefix `P` are `// P:` and its variants, matched in the order written, as FileCheck does:

- `P` matches at or after the end of the previous match;
- `P-NOT` requires the pattern nowhere in the output. This is stricter than FileCheck, which looks only between the neighbouring matches, and some fixtures rely on it;
- consecutive `P-DAG` lines match in any order, without overlapping, after the previous match; the next line continues after the last of them;
- `P-LABEL` lines are matched first, in order, and split the output into blocks: the lines after a label must match before the next label's match;
- `P-SAME` must match later on the same output line as the previous match;
- `P-NEXT` must match on the line right after the previous match.

A pattern is a literal substring, except for spans in double braces, which are regular expressions; a match never spans lines, and `^` and `$` anchor at line boundaries. Any other `-` variant of a prefix is a hard error. If the harness skipped variants it did not know, a misspelled directive would leave a fixture green while it asserted nothing, and a check that cannot fail is worse than no check. The whole-program harness shares the parser but keeps the older order-insensitive matching, in which every positive line only has to appear somewhere.

Until 2026-10-24 the harness read only the first RUN line, ignored custom prefixes and the exit status, and matched `CHECK` lines in any order (review-bug-list SD-5, SD-21). `test/codegen/CodegenHarnessSelfTest.hpp` now pins each of those rules with a fixture the harness must reject.

Two more directives change how a fixture runs. A line `// UNSETENV: NAME` runs the compiler without that environment variable, for a fixture that must not see a switch a test run sets for every compile. A file containing `XFAIL:` anywhere is skipped before anything runs. The harness has no mode in which a fixture runs and is expected to fail, so marking a fixture `XFAIL:` removes its check as surely as deleting the file would.

## Inputs only a fixture can state

Most of the eco set pins ordinary lowering, grouped by subject in the file names: arithmetic and the edge cases of Int and Float, boxing, constructing and taking apart values, closures and partial applications, strings and literals, globals, and safepoints. Four further groups exist because they reach properties that no Elm program can.

### Limits and their twins

Each heap limit has a fixture at the limit that must compile and a twin one past it that must be rejected, for record fields, closure arity and the other wide-object bounds. Python generator scripts write the wide-object fixtures, and both the scripts and their output are committed, because the harness runs whatever `.mlir` files the directory holds and never runs a generator.

A change to object layout lands its fixtures first, as pins that fail against the code as it stands, and the fix then turns them green. Seeing each fixture fail once shows that it can.

### Forged plans

Some passes decide something at the MLIR level, record the decision as a plan, and check the plan again during lowering to LLVM before acting on it. Three passes work this way: hoisting allocation capacity checks, marking functions that can never reach a collection, and finding the reachable code in a closed-world build. Their fixtures hand the back end a plan written by hand, sometimes deliberately wrong, and assert that it is accepted or refused. A capacity plan computed under a different allocation budget, for example, must be refused rather than applied. Environment switches can make every compile re-validate these plans, so the forging fixtures unset them. Otherwise a test run with validation on everywhere would reject them for the very fault they plant.

### The byte-fusion dialect

The byte-fusion operations have corner cases in byte order, bounds checks and UTF-8 that are cheaper to pin one operation at a time than through Elm programs. Every byte-fusion fixture is a JIT fixture of the same shape: write values with the dialect's write operations, read them back with its read operations, and print them. Reading back what was written is the oracle, so no reference implementation is needed. The fixtures cover signed and unsigned integers and floats of each width in both byte orders, UTF-8 and byte copies, bounds checks on incomplete input, loop-based decoders, and a few message shapes such as a length-prefixed packet.

### Upstream probes

A statepoint is LLVM's form of a call during which the collector may run. LLVM does not lower a statepoint call that returns a wide struct, so the back end caps how many fields a call returns directly. A set of probe fixtures and a script that runs them detect when an LLVM upgrade lifts that restriction, so the cap can be raised then.

## Why the harness is C++ inside the test executable

The harness is C++ code linked into the test executable because only there can a JIT fixture call into the runtime. A shell script that pipes MLIR through standalone tools cannot run this suite: its separate JIT cannot resolve the runtime's accessor functions, it scores rejection fixtures and skipped files wrongly, and it needs FileCheck and the compiler installed outside the build. A Python driver built on LLVM's lit tool offers nothing the C++ harness lacks, and it cannot share the `CHECK` parser and the spawned-child runner with the whole-program tests. The eco directory's `run_tests.sh` is only a stub that forwards to the C++ driver.

A fixture belongs to the code it pins. When a pass or operation is deleted, its fixtures are deleted with it, except those that pin operations that remain. Keeping them under `XFAIL:` would leave files that are skipped and assert nothing. The intent of a test lives in each fixture's header comment, usually naming the rule or design it serves, rather than in a separate checklist that drifts from the files.

## Examples of changes that fit the theory
A change fits when it adds one fixture per property, at the stage that makes the property visible, with a header that names the rule it pins.

- An added eco operation, verifier rule or pass gets one fixture per property, named `<subject>_<case>.mlir`. The reachability fixtures, the never-collects plan fixtures and the typed partial-application verifier fixtures have this shape.
- An added or moved limit edits the generator script, commits the script and its output together, and keeps a twin one past the limit that must be rejected.
- An added byte-fusion operation or encoding gets a JIT round trip plus boundary and incomplete-input cases, following the existing families.
- An added directive goes into the shared `CHECK` parser, so every harness that uses it gains the directive at once, with a hard error for malformed input.
- A bug found by an Elm program is reduced to MLIR and pinned with a fixture beside the Elm test that found it, so the lowering stays pinned even if the program changes.

## Examples of changes that would break the theory
A change breaks the theory when it makes a fixture quieter without the code becoming more correct, or when it lets the two harnesses differ by accident.

- Writing a RUN line or directive the harness does not support and working around the resulting error instead of teaching the harness the feature. Before 2026-10-24 unsupported RUN-line features were ignored, and fourteen fixtures' custom-prefix checks never ran.
- Deleting a fixture, or marking it `XFAIL:`, to make a pass change green. Both remove the check. Decide whether the property is obsolete, then delete the fixture and update its rule in the catalog, or still required, then fix the pass.
- Giving the byte-fusion set its own fixture runner again. It once was a near copy that lacked the nursery check and crash routing; both sets now share `runFixture`.
- Pinning a front-end bug with a fixture. Fixtures start from MLIR and cannot see typing or specialization mistakes; those belong in the compiler or whole-program tests.
- Adding a separate shell or Python driver. It would lose the runtime link, the shared parser and the spawned children; extend the C++ harness instead.

## References

Parent: [verification.md](verification.md).

- `test/codegen/CodegenIsolatedTest.hpp`: the eco harness and the shared fixture runner (`runFixture`, `parseRunLines`, `runsInProcess`, `runSubprocessTest`, `isExpectedFail`, `UNSETENV`, `eco_test::requireRegionNursery`).
- `test/codegen/CodegenHarnessSelfTest.hpp`: fixtures the harness must reject (exit status, prefixes, RUN lines, order).
- `test/bf-codegen/BFCodegenTest.hpp`: the byte-fusion suite, on the same runner.
- `test/CheckPatterns.hpp`: the shared `CHECK` parser and matcher (`extractCheckPatterns`, `extractCheckPatternsForPrefixes`, `verifyPatterns`, `CheckOrder`).
- `test/IsolatedTestRunner.hpp`, `test/SpawnedChildren.hpp`, `test/main.cpp`: child dispatch (`codegen <path>`, `bf-codegen <path>`) and suite registration.
- `test/RegionNurseryGuard.hpp`: the production-nursery check.
- `test/codegen/gen_wide_fixtures.py`, `test/codegen/gen_wide_limit_fixtures.py`: the wide-object generators.
- `test/codegen/run_llvm_statepoint_probes.sh`, `test/codegen/llvm_statepoint_struct_return_*.mlir`: the upstream probes.
- `runtime/src/codegen/ecoc.cpp`, `runtime/src/codegen/EcoRunner.cpp`, `runtime/src/codegen/EcoPipeline.cpp`, `runtime/src/codegen/Passes/`: the compiler driver, the in-process runner and the passes under test.
- `runtime/src/codegen/BF/`: the byte-fusion dialect.
- `runtime/src/codegen/EcoBackend.cpp`: where `ECO_CAPHOIST_VALIDATE` and `ECO_GCFREE_VALIDATE` are read.
- Fixtures to read first: `test/codegen/value_tuple2.mlir` (absence check), `test/codegen/caphoist_plan_stale_k.mlir` (forged plan, `UNSETENV`), `test/codegen/reach_basic.mlir` (option forwarding), `test/codegen/construct_record_2048_rejected.mlir` and `test/codegen/invalid_pap_arity_2048.mlir` (limit rejections), `test/bf-codegen/bf_read_u16_be.mlir` (round trip).
- `design_docs/invariants.csv`: rules the fixtures pin, among them CGEN_072 (gc-leaf), CGEN_074 (capacity hoist), CGEN_078 (list map template), CGEN_081 (reachability), HEAP_019 (object field limits), HEAP_078 (closure arity), HEAP_082 (production nursery) and SYS_008 (spawned children).
