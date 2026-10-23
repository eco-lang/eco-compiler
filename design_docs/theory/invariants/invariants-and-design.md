# Invariants and Design Records

Every phase of Eco, from name resolution in the compiler to the layout of objects in the runtime heap, obeys numbered rules kept in one flat catalog. The first rules in the catalog define the four representation models of a value and say that no phase may infer one model's rules from another's. The rest are grouped by phase, with a block of assumptions that every phase is forbidden to make. Each rule is checked by whatever verifier, test or script quotes its number. Nothing checks the catalog itself, so a rule stays true only when its author edits it in the same change as the code. The reasons for a rule are kept outside the catalog, in the plan or design note that produced it, and the rule, the code comments and the commit message all point back to that record. A C++ style guide and a commit style guide sit beside the catalog.

## Why the rules are written down

Eco's compiler is written in Elm and its back end in C++, and no type system spans the two. Elm's types end at the dialect the compiler writes out. C++'s types end at the kernel functions. The dialect's verifier checks one operation at a time, so a fact that spans operations, such as how a constructor is laid out or which signature a call must match, is decided once by the compiler and trusted by every later pass. A trusted fact that nobody writes down drifts: two passes come to hold slightly different versions of it, and nothing notices until a program crashes. The catalog is where those facts are written, one rule per line, each with a number that its checks can cite.

The catalog is an index of checks and does no checking of its own. Each rule is checked where that is cheapest: by an operation verifier in the C++ dialect, by an Elm checker that walks the compiler's own intermediate form, by a C++ or end-to-end test, by a guard script or by a formal model. The check quotes the rule's number in its error text or test name. A failing test therefore leads to the rule, and the rule leads through its source column to the module and the plan behind it. No build step reads the catalog, so the number quoted in both places is the whole link.

## The representation rules come first

The root document describes the four models: the ABI form of a value at a call boundary, the SSA form in the intermediate code, the heap form in an object field or closure, and the logical form that Elm gives it. In the catalog the representation block comes first, because every other block is read in its terms. Its opening rule says that a rule in one model implies nothing about another unless some rule explicitly links them. The code generation and heap rules are phrased in terms of the models rather than in terms of particular passes. A phase is then checked against the rules for the model it produces, and it does not need to know what its neighbor happens to emit.

The block exists because of one recurring bug: a phase reads a value's form in one model and assumes its form in another. A value that is a 64-bit integer in SSA may be an unboxed Int, or it may be a pointer. A phase that decides from the SSA type alone stores one of them the wrong way, and the collector later reads garbage from that slot. Two rules settle the commonest cases.

Only Int, Float and Char are ever stored unboxed in heap fields and closures. Each heap slot carries a two-bit kind saying whether it holds a pointer, an Int, a Float or a Char, so that the collector and debugging tools can tell the three unboxed types apart. The kind has no encoding for Bool or String, on purpose.

Bool is always a boxed value in storage. True and False are not objects on the heap. They are constants embedded in the pointer word itself, and their encoding makes the word's low bit equal to the one-bit SSA value. Converting a Bool between its SSA form and its stored form is a bit operation, so the heap needs no slot kind for an unboxed Bool.

The forbidden-assumption block does a different job from the positive rules. A positive rule says what holds. A forbidden assumption names a tempting inference and says it is wrong, because the same wrong inferences recur phase after phase and a positive rule alone does not stop a reader from making them. Three of them show the pattern:

- A primitive SSA type does not mean an unboxed heap slot. The layout metadata decides that.
- A pointer is not told from an embedded constant by its address range or by a test for null. A marker in the pointer word decides that, and every phase tests the marker.
- A constructor's tag does not determine its field layout.

A final meta-rule covers what the others miss: no phase may rely on a representation property that no representation rule states.

The opening rule names four models, but the block also has rows for an LLVM-level form. In practice LLVM is a fifth model, one that the opening rule does not name.

## How the catalog is laid out

The catalog is one file of 418 rules, one rule per physical line, with six columns: number, phase, category, status, description and source. People and agents grep the file and no tool parses it, and a single line per rule is the cheapest format for that use: a rule can be found with grep, compared with diff, and added in the same commit as the code it governs. [invariants.md](invariants.md) shows why the columns cannot be split naively.

The first part of the file is divided by banner lines into blocks in pipeline order:

1. The representation block.
2. The phase blocks: name resolution; type checking with its exhaustiveness and post-solve checks; the typed optimizations before specialization and their serialized form; specialization; the whole-program optimizations; code generation; heap layout; and two byte-level blocks.
3. The rules that span phases, then the forbidden assumptions.
4. Kernel input and output errors, deferred task input and output, ports, and lambda set specialization.

After the last banner, rows are appended in the order they are written, whatever their family. Higher-numbered heap and code generation rules, the liveness rules, the collector-model rule, and the system library and virtual DOM rules all sit there. Appending gives a plan an exact place to insert its rows and a simple grep to confirm they landed. The cost is that reading a family's block does not show every rule in the family; searching by the number's prefix does. A reader starting work on a phase reads the representation block, then the cross-phase and forbidden-assumption blocks, then the block for that phase.

A rule's number is a family prefix and a three-digit number, and numbers are never reused or renumbered. When a design is removed, its rows stay in the file with the status retired, a note of what removed them and their former text. Rule numbers appear in code comments, tests, plans and commit messages, and a reader who meets an old number must be able to find what it meant. A number that a plan skipped carries a comment saying it must not be used.

Each row's status is the author's claim about how the rule is checked. Seven values are in use, and no file defines them. Enforced means a verifier, checker, assertion or script rejects a violation. Tested means a test is the check. Documented means the rule is stated and nothing is claimed to check it. Implemented means a mechanism exists, usually behind a switch, without a dedicated check. Implied and structural mean the rule is true by construction. Retired means the rule no longer applies. Status is not a reliable measure of coverage, as [invariants.md](invariants.md) shows; to know whether a rule is checked, grep the code for its number.

Because nothing reads the catalog against the code, rows drift when code moves. About one row in eight names a module that no longer exists or describes code that has changed. Where a row and the code disagree, the code is the authority, and the fix is to amend the row.

Drift between a description and the code is checked mechanically only where it is most dangerous. The concurrent collector is the clearest case. Each of its TLA+ models describes specific code, and a canary pins a hash of that code. When the code changes, the canary warns; a strict build setting turns the warning into a failure. The right response is to audit the models it names and only then update the hash, since repairing the hash alone leaves a model that no longer describes the code. The agent instructions send anyone about to change the allocator to the models' guide first. Two other rules, whose violations no local check can see, have guard scripts of their own. One of them pins by hash the C++ files cited as evidence for the claims the compiler trusts about kernels, and fails the build when one changes.

[invariants.md](invariants.md) covers the rules themselves: how the one-line format is read, how a row links to the checks that cite it, what each status means in practice and how it decays, and how to add, amend or retire a rule.

## Where the reasons are kept

The catalog holds each rule as it is currently true, and nothing else. The reasons are spread over four other records, each holding what the others should not.

Plans hold the design discussion for a change: its status, its parent plan if it has one, why it is done, and the measurements that justify it. A large piece of work is planned phase by phase, with each phase's detailed plan written just before the phase is built, because earlier phases move code and change the numbers. That is why dates and measured results live in plans and not in the catalog. Many rows name a plan by path, so a rule can be followed back to the discussion that created it.

Design documents hold investigation reports. A report records a question, a method and a result. It is a snapshot and is rarely updated afterward, so its outcome has to be read from the plans and the code.

Commit messages hold the reason for each change, written for a reader who already has the diff. Bodies run to one paragraph per concern and name exact symbols, so that searching the history for a symbol finds the commit that explains it. Searching the history this way is the main route to designs that were tried and dropped.

Code comments hold the local reason and cite the rule's number.

[design-notes.md](design-notes.md) covers the design notes: a record of investigated ideas, not a description of the system. Each note is a snapshot of one investigation, which ends in one of four states. An adopted idea is rebuilt as code plus a rule. A rejected one fails a measured gate and its note stays as a postmortem. A superseded one is left as history or deleted. An open one is parked with a condition for reviving it. The deciding evidence is almost always a count or a side-by-side measurement on the compiler's own self-compile, so read a note's status against the code and the plans before trusting it.

## The two style guides

`STYLE.md` is the coding guide for the C++ runtime. Collector code is read to check its invariants, not only its behavior, so the guide asks for a comment stating the purpose of every class, field and public method, and the preconditions a caller must meet, such as holding a lock. It also asks for a compile-time size check on every heap object structure and a guard object for every value rooted on the stack. Parts of the guide describe structures the runtime does not have: a collector class and accessor that do not exist, pointers stored as offsets, a design directory that does not exist, and include guards where many allocator headers use `#pragma once`. Follow the code where they differ.

`GITSTYLE.md` is the commit guide. The subject is imperative and capitalized, names the concrete thing changed, and has no scope prefix. The body is in the present tense, wrapped at 100 columns, one paragraph per concern, and explains why. The guide forbids tool or assistant attribution trailers, without exception; the few commits that carry one are mistakes. The agent instructions do not yet point to the guide.

## Designs the record keeps as rejected

Several rules look arbitrary until the alternative they rule out is known. Each rejection below explains one of them.

Pointers are raw absolute addresses, with three embedded constants and a family of embedded constructors that have no fields. An offset design, with pointers measured from a heap base, many separate constants and a sentinel page, uses a small field in the pointer word to identify the constant, and treats a nonzero value in that field as the sign of a constant. That test cannot work when False's value in the field is zero. The marker test among the forbidden assumptions takes its place everywhere.

A constructor with no fields, such as Nothing, lives in the pointer word and never on the heap, so a live zero-field custom object on the heap is a bug; [value-representation.md](../value-representation.md) gives the equality argument behind this.

Each heap slot has a two-bit kind instead of a one-bit boxed flag, so that the collector and debugging code can tell Int, Float and Char apart. Arrays that mix several primitive types are deliberately outside that design.

Once type checking has produced typed output, no phase may work out a type variable's constraint, such as "must be a number", from the variable's name. The constraint travels as data in the typed output, and reading it again from the name would be a second derivation of a fact that is already decided.

Two rejections concern the catalog itself. The catalog has no condensed companion file of the most important rules: one file with banner blocks holds every rule, and the importance filter lives in the agent instructions, which name the representation, code generation, heap and forbidden-assumption blocks as the ones to read first. Obsolete rules are retired rather than deleted, for the reason given above.

## Changing the rules

A change fits when the rule, the plan, the check and the code move together, in one commit, with the row naming the plan that holds the reasoning. Nothing mechanical confirms that they do, so the discipline belongs to the author.

### Examples of changes that fit the theory
- A representation fact becomes a representation rule, or a linked clause of one. If it names a tempting shortcut, a forbidden-assumption rule goes beside it, together with the check that cites both.
- A subsystem with its own rules gets its own family prefix and a plan that records its design. Its rows go in a banner block or are appended after the last banner, and each one carries a status that says honestly whether it is documented, tested or enforced.
- A changed mechanism amends its rows in place, keeping their numbers, and the description is rewritten to state the rule as it holds. A change to one representation fact amends every linked representation and forbidden-assumption row together.
- Deleting a design retires its rows, with a pointer to the plan that removed it, and puts the dated facts in that plan.
- A commit names the concrete thing in its subject, and its body gives the reason and the constraint that forced the approach.
- A C++ file follows the style guide's naming and comment rules, with a compile-time size check on any heap structure.

### Examples of changes that would break the theory
- A special case in one phase that assumes another phase's representation, such as "this slot is a 64-bit integer, so it is unboxed". The models are independent, so the guess fails as soon as their rules differ. Cite or add the representation rule and drive the decision from the layout metadata.
- Writing to a published heap object from a kernel because "it is only a counter". Concurrent marking assumes no surviving object is ever written, so this breaks it with no error. Write into an object that is still being built, or allocate a fresh one.
- Changing allocator code and repairing the canary's hash without auditing the models. The models then describe code that no longer exists, and the canary means nothing. Audit the models it names first.
- Putting history into a row: dates, measurements or a running log of updates. A row is read as the rule that holds, so its history hides the rule. State the rule as currently true and put the history in the plan.
- Reusing a retired number or renumbering rows. Numbers are quoted across code, tests, plans and commits, and every old citation would point at the wrong rule. Take the next free number in the family.
- Marking a row enforced when nothing enforces it. The status then claims a check that does not exist. Use documented until a verifier or test cites the row.

## References

Parent: [eco.md](../../../THEORY.md). Children: [invariants.md](invariants.md), [design-notes.md](design-notes.md).

- `design_docs/invariants.csv`: the catalog. List the banners with `grep -n '^# [A-Z]'`, then read the REP_*, XPHASE_* and FORBID_* blocks, then the block for your phase. Rules behind this document: REP_001 (independent models), REP_ABI_002, REP_HEAP_001 (layout metadata decides storage), REP_HEAP_002 (two-bit slot kinds), REP_CLOSURE_001 and FORBID_CLOSURE_001 (Bool in closures), REP_LLVM_001 and REP_LLVM_002 (the LLVM-level form), FORBID_REP_001 to FORBID_REP_003, FORBID_LAYOUT_001, FORBID_META_001, FORBID_HEAP_001 (pointer or constant by marker), FORBID_HEAP_004 (collector threads write nothing the program reads), FORBID_HEAP_005, FORBID_SUPER_NAME_001 (no constraints from names), HEAP_044 (no live zero-field custom objects), HEAP_SNAPSHOT_001 (no writes after survival except by builders), LSS_022 and HEAP_081 (guard scripts). Retired examples: HEAP_047, HEAP_061, CGEN_055, KERN_007. A number not to reuse: LSS_012.
- `design_docs/invariant-test-logic.md`: the test design for each rule.
- `runtime/src/allocator/Heap.hpp`: the pointer word, its marker and the embedded constants.
- `STYLE.md`, `GITSTYLE.md`: the C++ and commit style guides.
- `CLAUDE.md`: the agent instructions, the blocks to read first and the pointer to `test/tla/README.md`.
- `test/tla/README.md`, section "The canary", and `test/tla/manifest.txt`: the collector models and their drift check.
- `plans/`: the plans. `plans/threaded-gc-master-plan.md` ("How this plan is used") shows how a large plan is staged. `plans/hpointer-representation-redesign.md`, `plans/2-bit-unboxed-migration.md` and `plans/null-cons-hpointer-embedding.md` record the representation decisions above. `plans/threaded-gc-04-frozen-published-heap.md` states the no-writes-after-survival premise.
