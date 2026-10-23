# The Numbered Invariants

The numbered invariants are 418 rules, one per line, in a single flat file. Each line gives a rule's number, its phase, a category, a status, the rule itself and the sources behind it. A rule is tested wherever a check is cheapest to write: an operation verifier in the C++ dialect, an Elm checker that walks the compiler's own intermediate form, a C++ or end-to-end test, a guard script or a TLA+ model. That check quotes the rule's number. The number quoted in both places is the only link, because no tool reads the file. A row therefore stays accurate only when it is edited in the same commit as its code and its check. About one row in eight has drifted, and the code is the authority when a row and the code disagree.

## One line per rule

The file is laid out for grep and diff. People and agents read it: the agent instructions require reading it before any change to code generation, the runtime or a representation; the working guides for performance and kernel work tell their readers to respect it; and plans cite rows by number. One physical line per rule is the cheapest form for that use. A rule can be found by its number, a change to it shows as a one-line diff, and it can be added in the same commit as the code it governs.

The cost is that the file has no reliable field structure. The header names six columns separated by semicolons, but descriptions contain semicolons too, and only a little over half the rows split into exactly six fields. The reliable reading is: the first four fields, then the description, then the last semicolon, then the source column. The plans that edit the file say outright not to "fix" the field count, since nothing in the build parses it. Here are the header and one row, the rule that a case expression's alternatives end only in a yield:

```text
id;phase;category;status;description;source
...
CGEN_028;MLIR_Codegen;ControlFlow;enforced;Every eco.case alternative region terminates with eco.yield and no alternative falls through past the end of a region; eco.return, eco.jump, eco.crash, and eco.unreachable are forbidden inside eco.case alternatives (except if nested under other non-eco.case regions that are never emitted directly by MLIR codegen);runtime/src/codegen/Ops.td and Compiler.Generate.MLIR.Expr
```

From `design_docs/invariants.csv`. Notice the semicolon in the middle of the description, which a naive split would treat as a column break. The source column here is free text joined with "and"; most rows use a list separated by vertical bars instead, naming Elm modules, C++ files, related rule numbers and plans.

The phase and category columns are free text. The same phase is spelled several ways, and most categories belong to a single row. They help a person reading one row, but they make poor search keys. Search by the number's prefix instead.

## Families and numbers

A rule number is a family prefix and a three-digit number. The prefix says what the rule constrains, and a longer prefix names a narrower contract inside a family. The representation family, for example, has sub-families for the calling convention, the intermediate code, heap storage, closures, aggregates, constants, the LLVM-level form and the boundaries between models. The largest families are code generation and heap layout, with over eighty rules each, then lambda set specialization and the byte-level operations.

The banner blocks follow the pipeline, in the order the parent document gives, and after the last banner rows are appended in the order they were written, whatever their family. So reading a family's block does not show the whole family, and a grep for the prefix does.

Numbers have gaps, and the gaps are deliberate. A deleted rule leaves its number unused. A number a plan reserved and then abandoned carries a comment saying it must not be reused. Some families were numbered first in a plan or design document, and only some of those numbers became rows. Numbers are never reused because they are quoted from plans, commit messages, code comments, test names and crash messages, and a reader holding an old number must land on the rule it meant. Renumbering even three rules means editing documents, tests and crash messages together, which is why the catalog avoids it.

## From a rule to its check

No table maps a rule to its test. Each check lives next to the code it constrains, and by convention it names the rule, so a failure leads back to the text. The checks take five forms, listed from the compiler side to the runtime side:

1. Elm checkers run over the compiler's intermediate forms in the compiler's test suite.
2. Validators built into the compiler run only when a debugging environment variable asks for them.
3. Dialect verifiers reject a malformed operation in the C++ back end. They cover the rules Elm cannot see, such as LLVM address spaces, aggregate lowering and collector layout.
4. C++ tests: FileCheck fixtures of hand-written MLIR, runtime and kernel unit tests, and Elm programs run end to end.
5. Guard scripts and models: a script for a single rule whose violation no local check can see, and the TLA+ models of the concurrent collector.

A dialect verifier shows how thin the link is. This is the check behind the row above:

```cpp
LogicalResult CaseOp::verify() {
  ...
    Operation *terminator = block.getTerminator();
    ...
    // CGEN_028: Alternatives must terminate with eco.yield only.
    // eco.return, eco.jump, eco.crash are forbidden inside eco.case alternatives.
    if (!isa<YieldOp>(terminator)) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.yield', got '"
             << terminator->getName() << "'";
    }
```

From `runtime/src/codegen/EcoOps.cpp`, `CaseOp::verify`. Notice that the rule's number appears only in a comment, and the error a user would see does not carry it. Many more verifiers enforce rules without naming them at all, so a grep for a number undercounts what the dialect enforces.

Because the number is the only link, it can point at the wrong rule. In the same file, the verifiers that stop a closure environment from being copied to or from the heap cite the number of the case tag-count rule. That number is the one a plan first proposed for the closure rule, before the plan found it taken and chose another, and the code carries the proposed number rather than the final one. The row that does state the closure rule is cited by no code at all.

### The Elm checkers

The Elm checkers carry most of the code generation rules, and three choices shape them.

They inspect the compiler's own intermediate form, not the program's output. Most code generation rules are about the structure of the emitted operations, and a failing end-to-end program does not say which phase broke which rule. The checkers walk the Elm data structure that the code generator builds before it prints MLIR, through shared helper functions, and never parse printed text. Checking printed MLIR would need a parser and would put the code generation and heap rules out of reach of Elm tests. Walking the syntax tree reaches most code generation rules without one. The price is that the Elm tree must keep mirroring the operations the compiler emits.

Each checker is a pair of modules. A logic module exports an expectation function, and a test module, whose description string starts with the rule's number and a short title, runs it. Every checker runs over one shared corpus of standard test programs. A rule therefore gets coverage of every program in the corpus for the cost of writing one checker.

The tests compile programs exactly as production does. The test pipeline calls the same list of pure steps that the build command runs, and a guard script fails if the test harness imports a compiler pass directly. A checker that runs a different middle end from the one users get proves nothing about their compiler, and a bug that only the production steps trigger would pass unseen.

A checker that cannot check its rule honestly is deleted rather than kept. The record projection checker, for instance, cannot relate a field read to the construction it reads from without use-def chains, so it is deleted and the test design records that rule as documented but not enforced. A checker that claims coverage it does not give is worse than none, because the row's status then promises a check that is not there.

### The test design document

A separate design document gives the planned check for each rule: the rule, the phase, the intermediate form inspected, the checking logic, the inputs and the oracle. It covers fewer than half the rules, and fewer than half its entries name the tests that exist. It is part plan for how each rule could be checked, part record of the checks that exist. Most of the test paths it names point at a directory that does not exist, since the checkers live under another, and a few name checkers that were deleted. Treat the checker files as the authority and the document as the design behind them.

## What a status claims

The parent document gives the seven status values. A status is the author's claim at the row's last edit, and the convention is to claim only what has shipped: a row becomes enforced when the checker that enforces it passes, and is not marked enforced while that checker is only proposed. Nothing checks the claim afterward, and it decays in both directions. More than a third of the rows marked enforced are cited by no source or test file. Sometimes a verifier enforces them without naming them, and sometimes nothing does: a whole block of byte-level operation rules is marked enforced and cited nowhere. Some rows marked documented are in fact checked by tests. Two rows are marked tested although their checkers were deleted. And one row's checker covers only half of what the row states.

Read a status as a lead. To find out what stands behind a rule, grep the compiler, the runtime and the tests for its number, then read what that check really tests.

## How rows drift

A row drifts when the code under it moves and the row does not. The catalog is edited by the person who changes the code, and no build step compares it with the tree, so every rename that forgets the catalog leaves a trace. Drift takes four forms, the first by far the most common:

1. A source column names a module that has been moved or deleted. Module moves in the middle end, the code generator's restructuring and the deletion of a group of aggregate passes account for most of the 52 verified stale rows.
2. A status outlives its check, as when checkers are deleted in a batch and their rows are left marked tested.
3. The description outlives the mechanism. One code generation rule says an aggregate construction has no producer, when the code generator emits it by default.
4. A number is cited for the wrong rule, as in the closure environment verifiers above.

The project builds a mechanical drift check only where drift is itself the danger, and each such check guards a single row. The TLA+ canary pins the code each collector model describes and warns when it changes, failing only under a strict build setting. The guard script for kernel claims fails the build when a C++ file cited as evidence changes without its hash being updated in the manifest, or when the manifest's pins and the cited files differ. The files it pins are those cited by the licensed rows of the lambda-set kernel table and by every row of the kernel type table; the table of purity and allocation facts that the optimizer reads cites C++ evidence in its rows but is not pinned, and neither is the runtime machinery that every kernel shares. The guard script for large heap objects checks that their bodies are read only through approved accessors. Elsewhere, when a checker turns out to be vacuous, the fix goes on the check side: the checker is rewritten and the row amended to say what is really checked.

## Adding, amending and retiring a rule

A rule normally lands in one commit with the code it governs, the checker that tests it and the plan that argues for it. Almost every commit that touches the catalog also changes compiler, runtime or kernel source, and most also change tests and a plan. The row names the plan in its source column, so the reasoning can be found from the rule.

A row's text changes in place. When a mechanism changes, the number, phase, category and status stay, and the description is rewritten or extended to state the rule as it holds. When a mechanism is removed, the row stays with status retired, the reason, and its former text. Both follow from citation by number: a reader holding a number from any plan, commit or comment must be able to find what it meant.

### Examples of changes that fit the theory
- A rule for a mechanism lands with the mechanism, as one line in the right banner block or appended after the last banner. It takes the next free number in its family, a status that matches what checks it at that moment, and a source column naming the module, the checker and related rules. The checker lands in the same commit with the number in its test description or error text, so the first failure leads to the rule.
- A change to a representation fact amends every linked representation and forbidden-assumption row together. The models are linked only by those rows, so amending one and not the others leaves two rows that contradict each other.
- A checker found to be weaker than its rule is made honest, and the row is amended to say what the checker really checks. The status then describes the check that exists.
- A rule whose violation no local check can see gets a guard script cited from the row, which puts a mechanical check exactly where drift would otherwise go unnoticed.

### Examples of changes that would break the theory
- A phase that relies on a neighbor's representation choice without a representation, cross-phase or forbidden-assumption row. The assumption is then invisible and unchecked, and it breaks when the neighbor changes. Add or amend the linking row and a checker that cites it.
- Weakening or deleting a failing checker without touching the row. The row then claims a check that is gone. Fix the phase, or amend or retire the row and say why.
- Renaming or deleting a module without grepping the catalog and the test design document for it. Stale source columns come from exactly this. Update every row and test path that names the module in the same commit.
- Reusing a freed number, renumbering rows, or keeping a number a plan has changed. Every citation of the old number then points at the wrong rule. Take the next free number and check the plan's final numbering before quoting it in code.
- Choosing a status by aspiration, such as enforced for something only reviewed. Readers trust the status to say whether a check exists. Use documented until a check cites the row.
- Compiling tests through a different pipeline from production to get past a failure. The test then proves nothing about the compiler users run. Fix the failure in the production steps.

## References

Parent: [invariants-and-design.md](invariants-and-design.md).

- `design_docs/invariants.csv`: the catalog. List the banners with `grep -n '^# [A-Z]'`. Banner order: REP, CANON, TYPE, NITPICK, POST, TOPT, ECOT, MONO, GOPT, CGEN, HEAP, BFUSE, BFOPS, XPHASE, FORBID, IO_ERR, KERNEL_TASK_IO, PORT, LSS; then append order (HEAP_036 onward, CGEN_070 onward, LIVE, GC_MODEL, SYS, VDOM).
- Rows named above: REP_001 (independent models); CGEN_028 (case alternatives end in a yield, the excerpt); CGEN_029 (case tag count) and CGEN_062 (no closure environment on the heap), the misused number; CGEN_025, CGEN_034 and REP_AGG_001 (descriptions outlived by the code); MONO_019 and XPHASE_011 (marked tested, checkers deleted); MONO_005 (checker covers half the rule); BFOPS_001 to BFOPS_031 (enforced, uncited); MONO_021, LSS_038 and CGEN_079 (checkers made honest); GC_MODEL_001, LSS_022 and HEAP_081 (guard scripts); LSS_012 (a number not to reuse); GOPT_001 to GOPT_003 (the one renumbering). Retired examples: CGEN_055, HEAP_047, HEAP_061, KERN_007.
- `runtime/src/codegen/EcoOps.cpp` (`CaseOp::verify`, `PapExtendOp::verify`, `ToHeapOp::verify`, `FromHeapOp::verify`) and `runtime/src/codegen/Ops.td`: verifiers that enforce rows and name some of them.
- `compiler/tests/TestLogic/`: the Elm checkers, one directory per phase. `TestLogic/Generate/CodeGen/Invariants.elm` holds the syntax tree helpers; `CaseTagsCount.elm` and `CaseTagsCountTest.elm` beside it show the checker pair. The corpus is `SourceIR.Suite.StandardTestSuites`.
- `compiler/tests/TestLogic/TestPipeline.elm`, `compiler/src/Compiler/Pipeline/Steps.elm`, `test/scripts/check-test-pipeline-production.sh`: how tests compile like production.
- In-compiler validators under `ECO_MONO_VALIDATE=1`: `Compiler.Monomorphize.ValidateLayout`, `Steps.checkClosureStaging`.
- `test/codegen/`: FileCheck fixtures.
- `test/scripts/check-tla-manifest.sh`, `test/scripts/check-kernel-license-manifest.sh`, `test/scripts/check-large-body-access.sh`: the guard scripts. `test/tla/README.md` ("The canary") and `test/tla/manifest.txt`: the collector models' drift check.
- `design_docs/invariant-test-logic.md`: the per-rule test design.
- `plans/kernel-opt-07-kernel-facts-table.md`, `plans/kernel-opt-08-kernel-gcleaf-stamp.md`: the file's format rules and the shipped-status convention. `plans/cgen-invariant-tests.md`: checking code generation rules on the syntax tree.
