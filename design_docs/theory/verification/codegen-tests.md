# Codegen Tests

Generated MLIR and the lowering passes are tested with fixtures: small hand-written MLIR files that each pin one property. A fixture goes straight into the back end with no Elm compiler involved, either through the back end's command-line compiler run as a separate process or through the JIT inside the test process. Comment lines in the fixture name the stage at which the back end stops and the text its output must or must not contain, in the style of LLVM's FileCheck tool. There are two sets, each with its own harness: one for the eco dialect and one for the byte-fusion dialect, which implements fused encoding and decoding of Elm's `Bytes`. Because the input is written by hand, a fixture can state inputs the Elm front end never produces, such as objects past the heap's size limits or malformed operations that the dialect's verifier must reject.

## One property, at the stage where it shows

A whole Elm program exercises hundreds of operations at once, so a wrong lowering of one of them can hide behind the others and the program can still print the right answer. A fixture uses a handful of operations, stops the back end at the stage where its property is visible, and checks that property alone. When it fails, the property it names is broken and nothing else is in the way. Each fixture's header comment says which rule or design it pins, so a failure leads straight to the rule.

The second reason for this layer is reach. The front end checks a program before it becomes MLIR, so no Elm source can produce a record one field past the limit, a closure with too many arguments, a deliberately wrong pass decision or an operation with the wrong kind of slot. Hand-written MLIR produces all of these. The whole-program harness has no mode for an expected compile error, so a check that some input is rejected belongs here or in the compiler's own Elm tests.

The cost is that a fixture says nothing about whether the compiler ever emits the MLIR it contains. That is why an added lowering gets both a fixture here and an Elm program that reaches it from source: the fixture pins the lowering, the program pins the compiler's use of it.

## How the fixtures run

Each set's harness finds its fixtures by listing every `.mlir` file in its directory and makes each file one test, named `codegen/<file>` for the eco set and `codegen-bf/<file>` for the byte-fusion set, so a `codegen` filter selects both. The harness reads the stage from the first `// RUN:` comment line that names one. Every test runs in its own spawned child process, in parallel with the others, so a crash or a corrupted heap fails one fixture and leaves the rest alone. Both sets are suites inside the main test executable rather than separate runners, which is how they share the isolated-child runner and the `CHECK` parser with the whole-program tests. On Windows both suites are built over a directory that does not exist and run nothing.

```
fixture.mlir --(stage, from the first RUN line)--> harness
harness --(JIT stage)--> in-process runner --(printed values)--> matcher
harness --(dump stage, rejection, or expected crash)--> compiler subprocess --(IR text or diagnostic)--> matcher
matcher --(CHECK lines from the fixture)--> pass or fail
```

The byte-fusion harness is a near copy of the eco one that lacks several of its features. It does not check which nursery the heap uses, does not send crashing fixtures to a subprocess, and does not handle the reachability option or the directive that unsets an environment variable. Those are described below as the eco harness's behavior; a byte-fusion fixture that depends on one of them does not get it.

## What a fixture looks like

A fixture is one `.mlir` file. Its first `// RUN:` comment line names the stage, its `// CHECK` comment lines are the assertions, and everything else is the MLIR input. This one pins that a two-field tuple used only as a value lowers to an LLVM struct and allocates nothing on the heap.

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

The property under test, that nothing is allocated, is carried only by the two `CHECK-NOT` lines, each checked against the whole output. The positive lines show the shape the lowering produces instead. The `%ecoc` and `%FileCheck` spelling keeps the file readable as an ordinary LLVM test, but the harness does not run FileCheck: from this line it takes only the stage named by `-emit=`.

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

The harness reads a fixture's directives itself, and its rules are narrower than FileCheck's. A fixture checks only what its recognized `CHECK` lines name, so a fixture written with full FileCheck in mind can look thorough and assert less than it appears to.

The harness takes three facts from the RUN lines:

1. the stage, from the first RUN line that names one, so any later RUN line never runs;
2. whether the fixture expects the compile or run to fail, marked by `not %ecoc` anywhere in the file, which sends a JIT fixture to a subprocess and lets it fail;
3. whether the closed-world reachability option is present, which it passes on to the compiler.

Everything else on a RUN line, such as an environment prefix or a FileCheck option like a custom check prefix, has no effect.

The assertions are the comment lines that begin with the plain `// CHECK` prefix. A line under any other prefix is an ordinary comment to the harness. Each recognized form is matched against the whole output:

- `CHECK` requires the pattern somewhere in the output;
- `CHECK-NOT` requires it nowhere in the output;
- `CHECK-DAG` and `CHECK-LABEL` behave exactly as `CHECK`;
- `CHECK-SAME` must match later on the same output line as the previous positive match;
- `CHECK-NEXT` must match on the line right after the previous positive match.

Plain `CHECK` lines are not ordered with respect to each other. To pin an order, chain `CHECK-NEXT` or `CHECK-SAME` from a positive match. A pattern is a literal substring, except for spans in double braces, which are regular expressions. Any other `CHECK-` variant is a hard error. If the harness skipped variants it did not know, a misspelled directive would leave a fixture green while it asserted nothing, and a check that cannot fail is worse than no check.

When the compiler runs as a subprocess, the harness never looks at its exit status, for any fixture: the matched output is the whole verdict. A rejection fixture therefore needs a `CHECK` line on the diagnostic, since that line is the only thing that proves the input was rejected. For the same reason, a fixture whose only assertions are `CHECK-NOT` lines passes even when the compiler fails, so an absence check needs at least one positive line beside it, as the fixture above has.

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

- Writing checks under a custom check prefix, or in the commands of a second RUN line. The harness reads neither, so those checks never run. Use plain `CHECK` lines and one RUN line, or teach the harness the feature first.
- Deleting a fixture, or marking it `XFAIL:`, to make a pass change green. Both remove the check. Decide whether the property is obsolete, then delete the fixture and update its rule in the catalog, or still required, then fix the pass.
- Copying a harness fix into only one of the two harnesses. They are near copies, and a fix such as the nursery check or crash routing that lands in one leaves the other set unprotected. Land it in both, or extract the common part.
- Pinning a front-end bug with a fixture. Fixtures start from MLIR and cannot see typing or specialization mistakes; those belong in the compiler or whole-program tests.
- Adding a separate shell or Python driver. It would lose the runtime link, the shared parser and the spawned children; extend the C++ harness instead.

## References

Parent: [verification.md](verification.md).

- `test/codegen/CodegenIsolatedTest.hpp`: the eco harness (`runCodegenTest`, `parseEmitMode`, `isExpectedFail`, `isExpectedCrash`, `UNSETENV`, `--exe-reachability` forwarding, `eco_test::requireRegionNursery`).
- `test/bf-codegen/BFCodegenTest.hpp`: the byte-fusion harness. `test/bf-codegen/run_tests.sh` is an older grep runner that the build does not use.
- `test/CheckPatterns.hpp`: the shared `CHECK` parser and matcher (`extractCheckPatterns`).
- `test/IsolatedTestRunner.hpp`, `test/SpawnedChildren.hpp`, `test/main.cpp`: child dispatch (`codegen <path>`, `bf-codegen <path>`) and suite registration.
- `test/RegionNurseryGuard.hpp`: the production-nursery check.
- `test/codegen/gen_wide_fixtures.py`, `test/codegen/gen_wide_limit_fixtures.py`: the wide-object generators.
- `test/codegen/run_llvm_statepoint_probes.sh`, `test/codegen/llvm_statepoint_struct_return_*.mlir`: the upstream probes.
- `test/codegen/run_tests.sh`: the stub that forwards to the C++ driver; its header gives the reasons a grep runner cannot serve the suite.
- `runtime/src/codegen/ecoc.cpp`, `runtime/src/codegen/EcoRunner.cpp`, `runtime/src/codegen/EcoPipeline.cpp`, `runtime/src/codegen/Passes/`: the compiler driver, the in-process runner and the passes under test.
- `runtime/src/codegen/BF/`: the byte-fusion dialect.
- `runtime/src/codegen/EcoBackend.cpp`: where `ECO_CAPHOIST_VALIDATE` and `ECO_GCFREE_VALIDATE` are read.
- Fixtures to read first: `test/codegen/value_tuple2.mlir` (absence check), `test/codegen/caphoist_plan_stale_k.mlir` (forged plan, `UNSETENV`), `test/codegen/reach_basic.mlir` (option forwarding), `test/codegen/construct_record_2048_rejected.mlir` and `test/codegen/invalid_pap_arity_2048.mlir` (limit rejections), `test/bf-codegen/bf_read_u16_be.mlir` (round trip).
- `design_docs/invariants.csv`: rules the fixtures pin, among them CGEN_072 (gc-leaf), CGEN_074 (capacity hoist), CGEN_078 (list map template), CGEN_081 (reachability), HEAP_019 (object field limits), HEAP_078 (closure arity), HEAP_082 (production nursery) and SYS_008 (spawned children).
