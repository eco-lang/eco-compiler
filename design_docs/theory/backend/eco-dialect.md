# The eco dialect

The eco dialect is the set of typed operations in which the Elm-written compiler hands a fully specialized program to the C++ backend, and its verifier is the check made on that program each time it is read. About 140 operations describe the program as case expressions, constructions and projections of heap objects, closures and calls, primitive arithmetic and typed replacements for common kernel functions. Values have one opaque boxed type, plain machine types for unboxed Int, Float, Char and Bool, and six aggregate types that exist only in the intermediate code. The verifier guarantees only facts that one operation shows and that are cheap to test: a case expression is well formed, each stored field's declared kind equals its operand's type, no single-bit Bool goes into a heap or closure slot, objects fit the sizes the heap header can encode, no constructor is built as a heap object with zero fields, and every referenced symbol exists. It does not check that a direct call matches its callee's signature, and it does not check the tuple and list layout attributes that the lowering reads.

## The compiler describes values, the lowering decides memory

The dialect keeps the functional structure of the program until the backend chooses how memory is laid out. Data types, closures and pattern matches stay as operations instead of becoming loads, stores and branches, so the lowering, which knows the collector, decides each layout. The operations that allocate raw memory exist in the dialect, but only the lowering introduces them. The compiler never writes one, which means it never describes memory, only values.

The verifier follows from the same division of work. Whatever it proves, the lowering may assume. Whatever it does not prove, the lowering takes on trust from the compiler. The verifier runs on every operation each time a module is parsed, so it is kept to checks that look at one operation, or at most at one symbol found through MLIR's cached symbol table. A check that needs the whole module belongs in a pass.

## Types

The types make a value's form in the intermediate code explicit and keep it separate from its layout in the heap. There are three kinds.

The boxed type, written `!eco.value`, is one machine word. It holds either the address of a heap object or an embedded constant, told apart by a bit in the word. True, False, the empty list and every constructor with no fields are embedded constants. How the word is encoded, and what each Elm type becomes in each representation, is described in [value-representation.md](../value-representation.md).

Elm's primitives are plain MLIR types: Int is a 64-bit integer, Float a 64-bit float, Char a 16-bit integer and Bool a single bit (`i1`). The single-bit Bool exists only in the intermediate code. In heap fields, closures and at call boundaries a Bool is always boxed, as one of the two embedded constants.

Six aggregate types hold a small group of values outside the heap: a pair, a triple, a record, a custom-type value, a list cell and a closure environment. They lower to LLVM struct values and never to heap pointers.

None of these types carries heap layout. A constructor's tag, for example, is an attribute of the operation that builds or boxes the value, not part of any type. That lets one aggregate type describe a value whether it ends up in registers or in a heap object.

## Operations

The operations group by what they describe, from control flow inward to memory. Each group's shape follows from one decision about who knows what.

| Group | What it holds | Why it has this shape |
|-------|---------------|------------------------|
| Control | A case expression that produces a value, its yield, join points (labeled blocks a function can jump to with arguments) and jumps to them, return, crash, and a debug print | Elm's case is an expression, and a value-producing case lowers directly to structured if and switch |
| Heap objects | One construction and one projection per runtime layout (list cell, pair, triple, record, custom type, closure), tag extraction, embedded constants, boxing and unboxing, module-level globals | Each allocation and projection commits to one runtime layout, whose header tag matches the runtime's type |
| Closures and calls | Creating a partial application (a closure holding some but not all of its arguments), creating a group of mutually recursive closures, extending a partial application, and calls that are direct by name or indirect through a closure | A call states whether its target is a named function or a closure and how many arguments remain, so the lowering works out neither |
| Primitive arithmetic | About 75 operations on Int, Float, Char and Bool | Elm defines results the machine does not, such as integer division by zero giving 0, so each operation names the Elm meaning |
| Typed intrinsics | String operations, list append and map, array operations, structural equality, comparisons returning an Elm `Order` | Each replaces a call to a generic kernel function with an operation the lowering specializes by type |
| Aggregates | Building each aggregate type, moving a value between aggregate and heap form, building a closure | The compiler keeps short-lived values out of the heap and states where they must be boxed |
| Never written by the compiler | Raw allocation of objects, strings and closures; six reference-counting placeholders | Allocation belongs to the lowering; the placeholders keep a design option open and never reach code generation |

Join points exist because a value-producing case cannot jump out of one of its branches. Tail recursion is therefore written as a jump to a join point, which lowers to a loop.

Every operation is declared in one TableGen file, and MLIR generates the C++ classes from it. All hand-written logic lives in one C++ file: the verifiers, the symbol checks, the folds, the effect declarations for calls, and the custom printing of case expressions and join points. The C++ file that registers the dialect and its types (`EcoDialect.cpp`) contains no logic of its own.

The declaration of the custom-type construction shows several of the dialect's rules in one place. Record and closure operations follow the same pattern.

```tablegen
def Eco_CustomConstructOp : Eco_Op<"construct.custom", [Pure]> {
  ...
  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<StrAttr>:$constructor,
    // One kind (0 boxed, 1 Int, 2 Float, 3 Char) per field (HEAP_019).
    DenseI8ArrayAttr:$slot_kinds
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;
  ...
}
```

From `runtime/src/codegen/Ops.td` (`Eco_CustomConstructOp`).

Notice three things. The operation is marked pure although it allocates; the section on effects explains what keeps that safe. The fields are one variable-length operand list, and the verifier requires its length to equal `size`. The tag is an attribute of the operation, not part of a type.

## What the verifier checks

### Each field's kind agrees with its operand's type

Records, custom types, closures and the conversion of an aggregate to heap form carry one small number per field, saying what the field holds: 0 for a boxed value, 1 for Int, 2 for Float and 3 for Char. The verifier works out the kind from each operand's MLIR type and requires the attribute to equal it.

```cpp
static uint8_t fieldKind(Type t) {
  if (t.isInteger(64)) return 1;
  if (t.isF64()) return 2;
  if (t.isInteger(16)) return 3;
  return 0;
}
...
  for (unsigned i = 0; i < slots.size(); ++i) {
    Type t = slots[i];
    // B14: Bool is boxed in heap fields (REP_CLOSURE_001 / FORBID_CLOSURE_001).
    if (t.isInteger(1))
      return op->emitOpError(what) << " " << i
             << " has i1 type: Bool must be boxed to !eco.value before construction";
    const uint8_t k = fieldKind(t);
    ...
    const int8_t want = kinds[i];
    ...
    if (uint8_t(want) != k)
      return op->emitOpError("slot_kinds[") << i << "] = " << int(want)
             << " does not match operand type " << t << " (kind " << int(k) << ")";
  }
```

From `runtime/src/codegen/EcoOps.cpp` (`fieldKind`, `verifySlotKinds`).

The type decides the kind, and the attribute is only compared with it. That is why the lowering never reads `slot_kinds`: it derives every layout from the operand types, so the attribute is a cross-check on the compiler and never a second source of truth. It is kept because it is the only check in a production build that the compiler's idea of a layout agrees with the values it passes in.

A single-bit operand is rejected outright rather than given a kind. The collector reads every kind-0 slot as a boxed word, and a bare 0 or 1 stored there is not one. For closures the same ban sits on the operations that create and extend partial applications, since those are the operations that store values into a closure.

The kinds are a list of small integers, one per field, because the compiler is written in Elm, whose Int is exact only up to 2^53, so it cannot emit a packed 64-bit word of kinds. Two bits per field are needed, not one: a single "unboxed" bit assumes every unboxed field is an Int, and corrupts Float and Char values when they are boxed again.

Packed bitmap attributes on these operations are rejected by the verifier, not ignored. MLIR would otherwise carry them as unknown attributes and drop them silently, and a stale cached module must fail loudly instead.

### A case expression is well formed

A case expression matches one value, the scrutinee, against a list of tags, one per alternative. The verifier requires one tag per alternative region, a case kind of constructor, integer, character, string or Bool, a scrutinee type that agrees with that kind, Bool tags of 0 or 1, and, for a string case, one string pattern fewer than alternatives. The case has at least one result. Every alternative is a single block that ends in a yield whose types equal the results.

The yield rule is strict on purpose: any other terminator in an alternative is an error. A value-producing case lowers to structured control flow, which has no way to leave a branch early, so a return inside a branch would have nowhere to go. A Bool scrutinee may be a single bit, so that matching on a Bool does not box it.

### Objects fit the header

The size limits come from how the heap header records field kinds. A custom-type object keeps the kinds of 24 fields in its header and a record those of 32. Either can add up to 63 extra words of kinds, 32 fields each, a bound set by a 6-bit header field and by the rule that objects stay below the large-object threshold. That gives a custom type at most 2040 fields.

A record could reach 2048 fields, but it is capped at 2047. A record type's constructor function takes one argument per field, and a closure's arity is an 11-bit field whose largest value is 2047. With the cap, every record constructor is usable as a function value, and so is every custom-type constructor. Keeping a closure arity of 63 with an error past it would leave large constructors unusable as function values, and staging them through curried wrappers is rejected too, so the limits are wide instead.

A closure has at most 2047 parameters and fewer captured values than parameters, so at most 2046 captures. The verifier reads all of these limits from the runtime's heap header definitions, so the verifier and the collector cannot disagree about them.

### A constructor with no fields has one representation

A constructor with no fields is always an embedded constant, and building one as a heap object with zero fields is a verifier error. The reason is equality. The equality paths answer "not equal" as soon as the two words differ and either side is embedded, so a heap copy of a nullary constructor would make equal values compare unequal. The embedded constant's tag is also checked against the range the word can encode.

### Calls and closures agree with themselves

A call is either direct, naming its callee, or indirect, through a boxed closure with the number of arguments it supplies stated as the remaining arity. A direct call may not also carry a remaining arity, and an indirect call's remaining arity must equal the number of arguments it passes. Extending a partial application in the generic way must produce a boxed value or a primitive. A group of mutually recursive closures must have consistent counts per member, references between members within bounds, and boxed slots for the members it captures. List map checks its element kinds and that a callee's parameters match its captures.

### Referenced symbols exist

Callees, globals, global initializers and fast evaluators must exist, and a kernel function used inside a closure must have a declaration. These checks run in a separate symbol-checking hook that MLIR gives every operation that refers to a named function or global. That hook uses MLIR's cached symbol table, so each check is one lookup, not a scan of the module.

One symbol check reaches across operations. When a typed extension of a partial application traces back, through other unsaturated typed extensions, to the creation of the closure, and the creation names a function with the right number of inputs, the verifier compares the extra arguments with that function's parameter types. In every other case it gives up silently. The check exists because a mismatch at that point otherwise reaches LLVM and aborts there with "Calling a function with a bad signature!", which says nothing about where the mismatch came from. It gives up rather than guess, so it never reports a false error.

### When the verifier runs

Parsing a module always runs the verifier. The developer tool `ecoc` also verifies after every pass. The production drivers skip verification between passes unless the build enables lowering validation, so a pass that writes invalid eco operations is caught only in test or validation builds. That follows from the parent's point that compile time decides the shape of the pipeline.

## What the verifier leaves to the compiler

Three facts the lowering depends on have no verifier behind them, and a change on either side of the dialect must keep them in mind.

A direct call's arguments are not compared with the callee's signature. Comparing every call and closure with its function's full signature would catch type mismatches early, but it needs module-wide symbol scans, and those scans dominate lowering time. In a normal build no check compares the two, and a mismatch surfaces in LLVM.

The two-bit mask that marks which fields of a pair or triple are unboxed, and the kind of a list cell's head, are attributes that the lowering reads directly. Only tests of the Elm compiler check them.

The remaining arity on indirect calls and the case kinds are checked only for consistency with the operation itself. Whether they match what the program means is the compiler's responsibility.

## Effects and folds

### Which operations may be merged or erased

Purity in the dialect is narrow, and a broad grant of it would be unsound. Most constructions, projections and arithmetic operations are marked pure. The fixed-size constructions and closure creation are pure even though they allocate, which lets MLIR erase one whose result is unused. Merging two of them would be wrong: two constructions that each hold a NaN are separate objects, and the equality fast path compares identity first, so merging them changes the answer of an equality test. The pipeline does not run MLIR's common subexpression elimination, for that reason and because it keeps memory alive longer, as [lowering-passes.md](lowering-passes.md) describes. That, not the trait, is what keeps allocations apart.

The variable-size allocating operations (list and string append, list map, the array allocators) and the extension of a partial application carry no traits at all. MLIR then assumes they have unknown effects and neither merges nor erases them.

A call declares its memory effects explicitly. Declaring them at all removes MLIR's default of unknown effects, so a call that is not marked must claim to read and write memory, or every call would become erasable. A direct call can carry a marker that lets it be merged or erased (`eco.cse_safe`). It never lets the call be moved ahead of the condition that guards it, since the call does not declare itself speculatable. The marker is a discardable attribute, one that MLIR lets any pass drop. The verifier allows it only on a direct call that is not a forced tail call, and the garbage-collection preparation pass strips it, so no pass after preparation can act on it.

Reads of heap values, such as string length, string comparison and structural equality, are marked pure. That is sound only because Eco heap values are never written after they are published.

### Folds rely on immutability

A projection from a construction that dominates it folds to the constructed field's operand, and a tag read of a custom-type construction folds to its tag. Heap objects are written once, so the field read back is always the operand written. The fold also requires the operand's type to equal the projection's result type exactly, which excludes operands that the lowering boxes on the way into the object.

The same folds for list head and tail exist but are off unless an environment switch enables them. Combined with common subexpression elimination, they break the lowering's rewrite of list traversals, so they stay off to keep that combination from being reached.

## No root operands

No operation carries the boxed values that are live across it. LLVM's statepoint rewriting finds the real roots from liveness, as the parent explains, and the compiler attaches none. Roots cannot be computed inside the lowering either: by then the type conversion has turned boxed values into plain integers, so liveness there cannot tell pointers from numbers. LLVM can, because boxed values reach it as pointers in their own address space.

The counting rule that follows is simple: every verifier and fold counts operands directly, and an operation's operand list holds exactly its declared operands. A record or custom-type construction must have exactly as many operands as its field count or size.

## Aggregates and closure building

The compiler emits pairs, triples and custom-type values as aggregates by default, and converts them to heap form where a value escapes. The dialect supplies the mechanism: the six types, the operations that build them and move values between aggregate and heap form, and their verifiers, which require each element type to equal the corresponding parameter of the result type. Escape analysis over the lowered code is the wrong place for this decision: there it allocates more, not less. So the compiler decides, and the backend only carries the decision out.

Before statepoint rewriting, LLVM promotes the aggregates to registers and folds field extraction. Statepoint rewriting cannot handle an aggregate value that holds a garbage-collected pointer across a call, so this order is required.

Building a closure has its own operation. It is the only aggregate operation that allocates, returns a boxed value and names a function, so the general conversion to heap form rejects a closure environment and the closure operation does that job. It keeps the closure limits and the single-bit ban of the partial-application operations.

## The byte-sequence dialect

Fused encoding and decoding of byte sequences uses a separate dialect, `bf`, described in [bytes-fusion.md](../compiler/bytes-fusion.md). It is kept apart so that the eco operations stay stable and byte fusion can be switched on or off without touching them.

## Reference-counting placeholders

Six operations for reference counting do nothing in a design whose collector traces. They are kept for possible experiments with reusing memory. Nothing emits them, and the first pass of the lowering reports an error for any that appears, so none reaches code generation.

## Where the written record disagrees with the code

Several descriptions of the dialect outside the code claim more than the code does, and a reader who trusts them will assume checks that do not exist. Trust the verifiers in `EcoOps.cpp`.

The design document on MLIR verification shows the call, closure-creation and extension verifiers checking full signatures; only the bounded extension check exists. It also says the closure-capture checking pass always runs before lowering and that verification runs between passes; that pass is compiled in, and inter-pass verification is on, only in validation builds. Comments in the call and extension verifiers say signature checking is deferred to that pass, but it checks only closure captures.

The dialect description in the TableGen file gives Char as a 32-bit integer and mentions a reference count in the header. Char is 16 bits, and the collector traces. The comment above the field fold says a kind-0 slot accepts a single-bit operand, which the slot-kind check rejects.

Some invariant rows are stale. Two say the aggregate operations have no producer, which the compiler's default output contradicts. One says the generic extension of a partial application always yields a boxed value; it can yield a primitive. Two rows and a few code comments cite the wrong identifier for the closure-environment and aggregate rules, and two rows mention a deleted allocation operation. The References list gives the identifiers.

## Examples of changes that fit the theory
A change fits when it keeps the verifier local, keeps layout derived from types, and gives every fact one representation.

- Another typed intrinsic is one operation with a precise description and a lowering pattern. Mark it pure only if it neither allocates nor has observable effects, or if it reads immutable data and its description says why. A variable-size allocating operation stays without traits. String and list append, structural equality, the code-unit read and list map have this shape.
- Another allocating operation declares exactly its own operands, with a verifier that checks their count against its declared size, and leaves rooting to LLVM's statepoint rewriting.
- Widening a size limit changes the constant in the runtime's heap header together with the header encoding. The verifier picks up the constant itself; add a rejected-input test at the edge, as for arity 2047 and fields 2040 and 2047.
- A tighter check becomes another case in an operation's verifier, or in its symbol check if it needs one lookup, with a negative test under `test/codegen/`. The bounded extension check is the model: walk a short way, and give up when unsure.
- An optimization hint is a discardable attribute with a verifier precondition and a defined pass that strips it, as the call purity marker has.
- Another consumer of aggregates uses the existing building, conversion and projection operations, so the set of types stays fixed and the boxing rules stay in one place.

## Examples of changes that would break the theory
- A walk over the module, or a signature lookup by scan, inside an operation's verifier. It runs on every parse and after every pass in validation builds, and that cost is why the verifier does not check signatures. Put whole-module checks in a pass, and use the symbol hook for a single cached lookup.
- Reading `slot_kinds` in the lowering, or deriving layout from anything but the operand types. It turns a cross-check into a second source of truth that can disagree with the first. Derive layout from the types.
- Tolerating a second representation for compatibility, such as a heap constructor with zero fields or a packed bitmap that is quietly ignored. Equality and stale caches both depend on there being one. Reject it in the verifier.
- Letting a single-bit Bool into a heap or closure slot, or an aggregate into a closure operand. The collector reads the slot as a boxed word. Box the Bool; closures take only boxed values and primitives.
- Adding a safepoint marker operation, or computing roots during the lowering. By then boxed values are integers and liveness cannot see them; fix a root problem in the LLVM types and attributes instead.
- Marking an allocating operation pure so that it can be merged. Object identity is observable through NaN equality; merging needs a guard that no Float is reachable.
- Adding a pass-specific attribute with no verifier check and no point where it is stripped. Unknown attributes are carried and ignored silently, so a wrong one is never noticed.
- Mixing the two dialects. Byte-fusion operations do not belong in eco, and eco semantics do not belong in the byte-sequence dialect, or neither can change without the other.
- Emitting a reference-counting placeholder in anticipation of reference counting. The lowering turns it into a compile error; reviving reference counting means designing its lowering first.

## References

Parent: [backend.md](backend.md). This node has no children. The consumers of the verified module are described in [lowering-passes.md](lowering-passes.md), and its producer in [mlir-generation.md](../compiler/mlir-generation.md). The byte-sequence dialect is described in [bytes-fusion.md](../compiler/bytes-fusion.md).

Code:

- `runtime/src/codegen/Ops.td`: the dialect, its seven types, the type constraints and every operation. Read the descriptions of `eco.case`, `eco.call`, `eco.papExtend`, `eco.list.map`, `eco.value.eq` and the value-aggregate section.
- `runtime/src/codegen/EcoOps.cpp`: `verifySlotKinds`, `verifyClosureKinds`, `rejectStaleBitmapAttr`, `CaseOp::verify`, `RecordConstructOp::verify`, `CustomConstructOp::verify`, `PapExtendOp::verifySymbolUses`, `CallOp::getEffects`, `foldConstructedField`, `ListHeadOp::fold`.
- `runtime/src/codegen/EcoOps.h` (`kCseSafeAttrName`), `runtime/src/codegen/EcoDialect.h` and `runtime/src/codegen/EcoDialect.cpp` (the dialect and its types).
- `runtime/src/allocator/Heap.hpp`: `CUSTOM_MAX_FIELDS`, `RECORD_MAX_FIELDS`, `CLOSURE_MAX_ARITY`, `NULL_CONS_MAX`.
- `runtime/src/codegen/Passes/EcoGCPrepare.cpp`, `runtime/src/codegen/Passes/RCElimination.cpp`, `runtime/src/codegen/Passes/CheckEcoClosureCaptures.cpp`, `runtime/src/codegen/EcoPipeline.cpp`: allocation grouping and the purity marker, the placeholder check, the validation-only capture check, and when verification runs (`ECO_LOWERING_VALIDATION`, off by default).
- `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp`: the aggregate promotion before statepoint rewriting.
- `compiler/src/Compiler/Eco/Config.elm` (`aggPromote`, `ctorInline`): the compiler's default aggregate output.
- `test/codegen/*_rejected.mlir`, `test/codegen/invalid_*.mlir`, `test/codegen/call_purity_attr_*.mlir`, `test/codegen/value_*.mlir`: what the verifier accepts and rejects.
- `compiler/tests/TestLogic/Generate/CodeGen/`: the tests that check tuple masks and list head kinds.

Invariants (`design_docs/invariants.csv`):

- REP_SSA_001, REP_BOUNDARY_002, REP_BOUNDARY_003, REP_CLOSURE_001, REP_CLOSURE_002, REP_AGG_001, FORBID_CLOSURE_001: representation of values, Bool boxing, aggregates.
- CGEN_003, CGEN_010, CGEN_020, CGEN_026, CGEN_028, CGEN_029, CGEN_037, CGEN_039, CGEN_053, CGEN_057, CGEN_061, CGEN_062, CGEN_063, CGEN_079: the dialect contract.
- HEAP_015, HEAP_019, HEAP_044, HEAP_078: layout tags, field kinds, embedded constants, size limits.
- Stale rows: CGEN_028 names a nonexistent `eco.unreachable`. (CGEN_025, REP_AGG_001, CGEN_034, CGEN_056, CGEN_039 and CGEN_079 were brought into line with the code on 2026-10-23, and the code comments now cite CGEN_061 and CGEN_062 for their rules.)

Design documents:

- `design_docs/globalopt/borrow-inference-design.md`: why aggregate production moved to the compiler.
