# Value representation

Outside the body of a single function, every Elm value except an Int, a Float or a Char is one 64-bit word, and bit 2 of that word says whether it is the address of a heap object or a constant embedded in the word itself. Int, Float and Char are raw machine values (a 64-bit integer, a 64-bit float and a 16-bit code unit) at calls, in closures and in heap fields. They become heap objects only where something must hold them as a boxed value, most often a type variable that specialization left unconstrained. Bool is a one-bit integer only inside a function, and everywhere else it is one of two embedded constants. Every heap object whose fields can hold a raw number records a two-bit kind for each field, so the collector can tell a raw number from a pointer without knowing any types, and the compiler computes each object's layout from the value's type, identically at every site that builds or reads one. A value changes form only at six seams: into a call or capture, out of one, at construction, at projection, between an SSA aggregate and the heap, and at LLVM's storage boundary. At each seam, code generation converts a value only when its actual type differs from the type the target expects.

## Each Elm value in each model

The four models are the ones [eco.md](../../THEORY.md) introduces: logical, SSA, ABI and heap. The SSA, ABI and heap forms are each computed by one function of the value's specialized type. The SSA type comes from `Types.monoTypeToOperand`. The ABI type comes from `MonoAbi.monoTypeToAbi`, which gives the same answer except that Bool is `!eco.value`. The ABI mapping sits beside the specialized syntax tree, not in code generation, so that phases that run before code generation, such as the inliner's cost model, can ask what a call will pass. The heap rule is `Types.canUnbox`, which is true for Int, Float and Char and for nothing else. The logical model is the Elm meaning, and equality, ordering and pattern matching are defined on it: two values are equal when they are the same Elm value, whatever forms they are in.

| Elm value | SSA (in a function) | ABI (call, capture) | Heap slot | Own heap object |
|---|---|---|---|---|
| Int | `i64` | `i64` | kind 01, raw i64 | `ElmInt` only when boxed into `!eco.value` |
| Float | `f64` | `f64` | kind 10, raw f64 | `ElmFloat` only when boxed |
| Char | `i16` | `i16` | kind 11, u16 in an 8-byte slot | `ElmChar` only when boxed |
| Bool | `i1` | `!eco.value` | kind 00, word `0x4`/`0x5` | never |
| `()`, `{}` | `!eco.value` | `!eco.value` | kind 00, word `0x6` | never |
| String | `!eco.value` | `!eco.value` | kind 00 | `""` is `0x6`, else a string object |
| List | `!eco.value` | `!eco.value` | kind 00 | `[]` is `0x6`, else Cons (head kind in header) |
| Tuple | `!eco.value` or `!eco.tuple2/3` | `!eco.value` | kind 00 | Tuple2/Tuple3, kinds in header |
| Record | `!eco.value` | `!eco.value` | kind 00 | Record, raw fields first, by name |
| Custom with fields | `!eco.value` or `!eco.custom` | `!eco.value` | kind 00 | Custom, `ctor` + kinds |
| Nullary ctor | `!eco.value` | `!eco.value` | kind 00 | never: `(idx << 43) \| 0b111`; `Nothing` is `0x6` |
| Function | `!eco.value` | `!eco.value` | kind 00 | Closure |
| Erased `a` | `!eco.value` | `!eco.value` | kind 00 | whatever the value is, boxed |

Apart from the aggregate forms, Bool is the only row whose SSA and ABI columns differ, and it is the row most often got wrong. Three other points in the table surprise newcomers.

A type variable that no use constrains is `!eco.value` in every model, so an Int passed through it is boxed into a 16-byte `ElmInt`. Every view of one runtime value must have a type with the same layout, and boxing everywhere is how an erased variable meets that condition: the code that holds the value as `a` and the code that holds it as `Int` agree on a single word. A `number` variable never gets this far: specialization closes every one to Int and fails if one survives, so the `number` cases in the type mapping are unreachable.

Char is one UTF-16 code unit, the unit in which the runtime stores strings, so a character read from a string fits a Char with no conversion. A code point above 0xFFFF has no Char, and `Char.fromCode` clamps its argument to 0xFFFF.

A tuple, or a value of a type with one constructor, can be held inside a function as an SSA aggregate, which LLVM sees as a struct and never as a pointer. It becomes a heap object only through `eco.to_heap`, at a boundary that needs a boxed value. The aggregate types belong to [eco-dialect.md](backend/eco-dialect.md), and when code generation produces them belongs to [mlir-generation.md](compiler/mlir-generation.md).

Below MLIR there is a fifth form, and it is mechanical. At each point where the collector may run, an LLVM pass records which stack slots hold heap pointers, and it finds them by following values of type `ptr addrspace(1)`. That pass is statepoint rewriting, RewriteStatepointsForGC. So `!eco.value` lowers to that type, and becomes an `i64` only where it is written to or read from a heap field, a global, a closure or an argument array. A pointer held as an `i64` across a collection point would be invisible to the rewriting and would go stale when the collector moved its object.

## The value word

The word that represents every boxed value is laid out so that a heap pointer is its own address. Bits 0 and 1 hold a constant code, bit 2 is the pointer indicator, set when the word is a constant, bits 3 to 42 are the pointer, and bits 43 to 52 index a nullary constructor. The struct and the codes are declared in `runtime/src/allocator/Heap.hpp` (comments trimmed):

```cpp
typedef enum {
    Const_False = 0,
    Const_True  = 1,
    Const_Empty = 2,
    Const_NullCons = 3,
} Constant;

typedef struct {
    u64 constant : 2;
    u64 ptr_ind  : 1;
    u64 ptr      : POINTER_BITS;   // 40
    u64 null_cons_idx : 10;
    u64 padding  : 11;
} HPointer;
```

Notice that the constant code and the pointer indicator take exactly the three low bits that an 8-byte-aligned address always has clear. A heap pointer has the indicator at 0, so its word is the raw address and a dereference needs no base to add and no shift. The heap is reserved below 2^43 so that an address never reaches the upper fields; that reservation belongs to [garbage-collector.md](runtime/garbage-collector.md). An embedded constant has the indicator at 1 and is never allocated or traced, so its word is 4 plus its code: False is `0x4`, True is `0x5`, Empty is `0x6`, and a nullary constructor is `(idx << 43) | 0b111`, where `idx` is its zero-based declaration index.

The encoding makes Bool's low bit equal its `i1` value. False is code 0 and True is code 1, so the SSA, ABI and heap views of a Bool carry the same bit. That choice is also why a pointer test cannot look at the constant code: False's code is 0, the same as a pointer's. The pointer indicator exists to make the test exact, and it is the only legal test. Code asks `isConstantBits`, never whether the constant code is nonzero, whether the word is null or whether it falls in an address range. All bit access goes through the helpers in `Heap.hpp`. The code generator has its own copies of the encoding for the LLVM lowering, and `static_assert`s and a runtime test of the exact words pin those copies to the helpers.

The rejected alternative is a 40-bit offset from a heap base with a constant index from 1 to 15, tested by "constant is nonzero". Every dereference pays an add and a shift, and its True and False share no bit with `i1`.

Empty is one constant shared by `()`, `{}`, `[]`, `Nothing`, `""` and empty Bytes. Merging them is safe because Elm is typed: the type checker ensures that each is produced and matched only where its own type is expected, so the word never has to say which empty it is. A distinct constant for each would gain only better display in the printer that works without types. The cost of merging is that a case expression cannot learn the constructor from the word. When the scrutinee is Empty, the case reads a reserved tag, `CONSTANT_TAG` (0xFFFD), instead. `Nothing`, `True` and `False` are fixed words rather than nullary-constructor constants.

A nullary constructor such as `LT` or `RBEmpty` is embedded, which saves a 16-byte heap object each time, and it must exist only in that form. Equality on boxed values decides "not equal" from unequal words as soon as either side is an embedded constant, both in the runtime's comparison and in the lowering of `eco.value.eq`. A heap copy of an embedded value would therefore make two equal values compare unequal. The same reasoning keeps every well-known constant out of the heap, the empty string included. String equality compares words when either side is Empty, so a heap string of length 0 would compare unequal to `""`; every producer returns Empty instead, and only the kernel's boxed-slot comparison treats the two as equal.

## Slot kinds and the header

Every slot in a heap object carries a two-bit kind: 00 for a boxed word, 01 for a raw Int, 10 for a raw Float and 11 for a raw Char. The collector reads these kinds, derives a one-bit pointer mask from them, and traces only the boxed slots. That is how it tells a raw integer from a pointer with no type information.

The two-bit kind is the reason only Int, Float and Char are raw outside SSA. Boxed plus three primitives fills the four codes, and the same four codes are used for a closure's parameter kinds, its result kind and the kinds in an evaluator descriptor. Bool does not need a code of its own, because boxing it costs nothing: boxing is a select between `0x5` and `0x4`, and unboxing is a compare with `0x5`, with no allocation either way. A raw Bool kind would spend one of the four codes for no saving. A one-bit "unboxed?" flag per slot is the rejected alternative: it cannot say which primitive a raw slot holds, so the runtime has to assume an Int, and it corrupts every Float and Char it re-boxes.

The header is 8 bytes. A 5-bit tag names the object kind, a 6-bit `unboxed` field holds kind information, and a 32-bit `size` gives the length. The remaining bits belong to the collector and are described in [garbage-collector.md](runtime/garbage-collector.md). Where the kinds live depends on how many slots the object can have:

- Cons, Tuple2 and Tuple3 keep a kind for each of their at most three slots in `header.unboxed`, two bits per slot, and a Task keeps the kind of its value field in the first two bits. ElmArray and ListBacking hold elements of one type, so they keep one kind for every element in those same two bits.
- Custom and Record objects can be large. Their kinds sit in a packed word after the header and, past what that word holds, in K tail kind words after the fields, and `header.unboxed` holds K.

A field always stays at `values[k]`, and the tail words carry kinds only. The rejected alternative caps the number of raw slots at 24 or 26 and stores any primitive field past the cap boxed, which makes a field's representation depend on its index. Tail kind words keep every primitive field raw at its own position.

## Layouts come from the type

A layout is a pure function of the value's specialized type, recomputed at every site that builds or reads an object. The functions live in `compiler/src/Compiler/Generate/MLIR/Types.elm`, and the expression emitter, the pattern compiler, the type table, the tail-recursion emitter, the logical-type strings and the code generator's driver all call them. No layout table is stored anywhere. Monomorphization supplies only each constructor's shape (its name, tag and field types). Layouts are computed in code generation because the MLIR back end owns the decision of what to unbox, and a pure function gives every builder and every reader the same answer with no table to keep in step. That needs one condition from specialization: every view of one runtime value has a type with the same layout.

Records, constructors and tuples each have their own ordering rule, and lists and closures have fixed shapes.

Records have one canonical order that does not depend on the source, and a field's slot is its position in that order. The object is `Header | kinds of slots 0..31 | values[n] | K tail kind words`, with at most 2047 fields, and `{}` is Empty and never allocated. From `computeRecordLayout`:

```elm
        ( unboxedFields, boxedFields ) =
            List.partition (\( _, ty ) -> canUnbox ty) allFields

        sortedUnboxed =
            List.sortBy Tuple.first unboxedFields

        sortedBoxed =
            List.sortBy Tuple.first boxedFields

        orderedFields =
            sortedUnboxed ++ sortedBoxed

        indexedFields =
            List.indexedMap
                (\idx ( name, ty ) ->
                    { name = name
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty
                    }
                )
                orderedFields
```

Notice that raw fields come first and boxed fields after, each group sorted by name, that a Bool field falls in the boxed group because `canUnbox` is false for it, and that `index` is the slot, not the source position. Sorting by name makes `{ x, y }` and `{ y, x }` one layout. Per-slot kinds would allow any order of raw and boxed fields, but projection indices, the type table, the logical-type strings and Debug output all rely on raw-first order, so changing it means changing all of them together.

Constructors keep declaration order, and their fields are named `field0`, `field1` and so on. The object is `Header | ctor:16, kinds of slots 0..23 :48 | values[n] | K tail words`, with at most 2040 fields. A constructor with no fields has no object.

Tuples keep element order. Their kinds go in `header.unboxed` as an integer, with slot i at bits 2i and 2i+1, which the compiler computes by multiplying by four and adding each kind. That is the only kind word the compiler packs itself. Every other object's kinds leave the compiler as one small number per slot, and the C++ lowering packs them. Packing a wide kind word in Elm with `Bitwise` is the trap this avoids: Elm's shifts wrap at 32 bits, so the kind of a slot at index 16 or more would overwrite the kind of slot index minus 16, and the collector would trace a raw Int as a pointer.

A Cons cell is `Header | head | tail`, with the head's kind in bits 1:0 of `header.unboxed`, and `[]` is Empty. The chunked list spines, and the forms of strings and bytes, belong to [runtime-data-structures.md](runtime/data-structures.md). A closure keeps the kinds of its first 20 parameters, captured or still to come, in its packed word and the rest in tail words; closure objects belong to [closures-and-calls.md](closures-and-calls.md).

The kinds reach MLIR as attributes on the construction operations: `slot_kinds` on `eco.construct.record`, `eco.construct.custom` and the closure operations, `unboxed_bitmap` on `eco.construct.tuple2` and `tuple3`, and `head_kind` on `eco.construct.list`. Which fields are raw is a layout decision made from the type, but the kind written for each slot is read from the SSA type of the operand that fills it. For records, constructors and closures, the lowering derives the kinds it packs from those operand types and never reads `slot_kinds`; the attribute is a cross-check that the verifier compares with the operands, a fact local to one operation ([eco-dialect.md](backend/eco-dialect.md)). The tuple bitmap and the list head kind are the other way round: the lowering packs them as given and the verifier does not check them, so a wrong one surfaces only at run time, in the collector or a heap validator. Deriving a kind or a type from the specialized type at the use site instead is a known way to send an `i64` where an `!eco.value` is expected.

## Where a value changes form

Each seam has one conversion, and code generation decides whether to apply it by comparing the value's actual SSA type with the type the target expects. It does not reason from the declared Elm type, because a declared type that does not match how a value is stored is exactly the bug the models exist to prevent.

| Seam | Conversion | What it costs after lowering |
|---|---|---|
| SSA to ABI: call arguments, returns, captures, partial applications | `eco.box` on an `i1`; `eco.box` on a primitive whose target is `!eco.value`, such as an erased parameter of a known callee. A call to an unknown callee passes the primitive raw, and the runtime boxes it if the callee's slot is boxed | Bool: a select between `0x5` and `0x4`. Primitive: allocates an `ElmInt`, `ElmFloat` or `ElmChar` |
| ABI to SSA | `eco.unbox` | Bool: compare the word with `0x5`. Boxed primitive: a load at offset 8 |
| SSA to heap: construction | raw `i64`, `f64` and `i16` stored as they are; `i1` boxed first | the verifier rejects an `i1` operand |
| Heap to SSA: projection | result typed by the slot's kind; a Bool field projected as `!eco.value` and then unboxed | a load at the slot's type |
| SSA aggregate to heap and back | `eco.to_heap`, `eco.from_heap` | `eco.to_heap` allocates the heap object |
| LLVM storage | `ptrtoint` and `inttoptr` | none; they appear only inside named helpers |

The LLVM storage helpers are the only place a pointer turns into an integer or back, and the conversions are kept from being folded away until statepoint rewriting has run. A check after that rewriting confirms that no other pointer-integer conversion exists, in GC-debug builds.

The runtime has one more re-boxing site: its generic apply re-boxes typed arguments from a closure's kinds ([closures-and-calls.md](closures-and-calls.md)). Where code generation places each conversion in practice belongs to [mlir-generation.md](compiler/mlir-generation.md).

## Finding a representation bug

A representation bug surfaces at the first check that can see it. The earlier the check, the more precisely it names the cause. In order of how early each is caught:

| Symptom | Likely cause | Where to look |
|---|---|---|
| MLIR verifier error on `slot_kinds` or an `i1` operand | Kinds or types computed from the specialized type instead of the operand | The operand types of the construct or closure operation; the `UnboxedBitmap` elm-test |
| LLVM "Calling a function with a bad signature!" | ABI mismatch at a direct `eco.call`, whose signature no verifier checks | `boxArgsToEvaluatorParams`; the callee's registered signature |
| Validator assert "Cannot resolve an embedded constant HPointer" | A raw Int with bit 2 set (7, say) read as `!eco.value` | The slot's kind, or the projection's result type |
| Validator assert "Pointer outside heap and permanent space", or a crash in the collector | A raw slot marked kind 00, so the collector traces an integer | The kinds emitted for the object |
| Wrong value printed, or equal values comparing unequal | A projection type that differs from the storage, or a heap copy of an embedded value | The slot kinds; whether a constant was allocated |

The validator asserts run only in heap-validating or Debug builds, and the pointer-integer check only in GC-debug builds.

## Examples of changes that fit the theory

- An added family of embedded constants, using a constant code that no pointer test reads. The nullary-constructor constants are the example: they use code 3, so every pointer-indicator test classes them as non-pointers with no change. They are built and decoded only through the `Heap.hpp` helpers and their code-generation copies under `static_assert`, and the verifiers and heap validation reject a heap object for a nullary constructor.
- Raising an object kind's slot capacity by adding kind storage while leaving field positions alone. Tail kind words are the example: they raise the capacity of records, constructors and closures, and touch neither SSA nor the ABI.
- A heap-only form of an existing logical value. Ropes, slices, UTF-8 strings and chunked lists are all `!eco.value` in SSA and at the ABI, so no compiled code changes when one is added. Only the runtime learns the form.
- Storing a primitive raw in a runtime container with the existing kinds. A Task's value field holds an Int, Float or Char raw, with its kind in slot 0 of `header.unboxed`.
- A boundary that needs a conversion, routed through `boxToEcoValue` or `coerceResultToType`, so that boxing is decided by the actual SSA type against the target's ABI type.

## Examples of changes that would break the theory

- Storing a Bool raw in a heap or closure slot because it is `i1` in SSA. The collector and every reader expect a word there. Box it to `0x4` or `0x5`, which costs no allocation.
- Adding a fifth raw kind, such as a raw Bool or a 32-bit Int, by reusing a code. Every kind word, the closure parameter and result kinds, and the collector's walkers assume four codes. A fifth kind means widening all of them together and amending the rule that fixes the kinds.
- Testing for a constant by asking whether the constant code is nonzero, whether the word is null, or whether it lies in an address range. False is `0x4`, with constant code 0, and passes none of those tests correctly. Use `isConstantBits`.
- Allocating a heap object for a value that has an embedded form, such as a zero-field Custom or a heap Nil. Equality would call equal values unequal. Return the embedded word, as `alloc::custom` does for an empty field list.
- Changing a layout at one site, for example ordering a record's fields differently in one emitter, or caching a layout. The other builders and readers keep the old answer. Change `computeRecordLayout` or its sibling itself, so that every site follows.
- Reading a boxed slot directly at a primitive type, such as a Bool field read as `i1`. Under an encoding where True and False share no low bit, this inverts every Bool case. With `0x5` and `0x4` the low bit happens to be right, so the mistake passes unnoticed until the encoding changes. Project at the slot's kind and then unbox.
- Removing a box and unbox pair as redundant without proving that the two forms are equal. The pair is where one model's form meets another's, and dropping it lets a value reach a slot or a parameter in the wrong form. Fold only a pair that is provably the identity, such as an unbox applied directly to a box of the same type.

## References

Code:

- `compiler/src/Compiler/Generate/MLIR/Types.elm`: `monoTypeToOperand`, `canUnbox`, `computeRecordLayout`, `computeCtorLayout`, `computeTupleLayout`, the slot kinds.
- `compiler/src/Compiler/AST/MonoAbi.elm`: `monoTypeToAbi`.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`: `boxToEcoValue`, `boxToMatchSignatureTyped`, `boxArgsForClosureBoundary`, `boxArgsToEvaluatorParams`, `coerceResultToType`. `Patterns.elm`: `generateMonoPathHelper` (projection then unbox).
- `compiler/src/Compiler/Data/CtorTag.elm`: which constructors embed, and `constantTag`.
- `runtime/src/allocator/Heap.hpp`: `Header`, `HPointer`, `Constant`, `isConstantBits`, `hpBits`, `hpToAddr`, `isEmptyBits`, `nullConsWordFor`, `HPOINTER_ADDRESS_LIMIT`, `CONSTANT_TAG`, the slot-kind accessors `customSlotKind`, `recordSlotKind`, `closureSlotKind`.
- `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`: `BoxOpLowering`, `UnboxOpLowering`, the `static_assert`s on the encoding.
- `runtime/src/codegen/Passes/EcoToLLVMInternal.h`: `value_enc`, the storage-boundary helpers (`heapStoreValueToI64`, `closureLoadI64ToValue`, `caseScrutineeToI64`).
- `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`: `EcoTypeConverter` (`!eco.value` to `ptr addrspace(1)`).
- `runtime/src/codegen/EcoTypes.cpp`, `EcoTypes.h`: empty; the eco types are declared in `Ops.td` and registered in `EcoDialect.cpp`.
- `elm-kernel-cpp/src/core/CharExports.cpp`: `Char.fromCode` clamping.
- `test/allocator/HPointerLayoutTest.cpp`: the exact-word test. `test/mlir_equivalence_main.cpp`: the MLIR-equivalence runner.
- Build settings: `ECO_HEAP_VALIDATE` or a Debug build for the validator asserts; `ECO_GC_DEBUG_LIVENESS` for `EcoPtrIntVerify`.

Invariants (`design_docs/invariants.csv`):

- REP_001: the four models. REP_SSA_001, REP_ABI_001, REP_ABI_002, REP_HEAP_001, REP_HEAP_002: each model's rules and the four kinds. REP_AGG_001: SSA aggregates. REP_LLVM_001, REP_LLVM_002: `!eco.value` in LLVM and the storage boundary.
- REP_BOUNDARY_001, REP_BOUNDARY_002, REP_BOUNDARY_003: projection and construction.
- REP_CONSTANT_002, FORBID_HEAP_001: the pointer test. REP_CONSTANT_003: says Empty equals a zero-length heap string; only the kernel's boxed-slot compare does so, and the rule holds because no producer makes such a string. HEAP_010, HEAP_044, CGEN_019: embedded constants and nullary constructors.
- HEAP_019, CGEN_026, CGEN_027: kind attributes and tail kind words. CGEN_065: logical-type strings in layout order.
- CGEN_013, MONO_029: erased variables are boxed; every view of a value has a layout-equal type.
- FORBID_REP_001, FORBID_REP_002, FORBID_REP_003: one model's form does not imply another's. FORBID_CLOSURE_001, FORBID_CLOSURE_002: Bool and kinds in closures. FORBID_LAYOUT_001, FORBID_DBG_001: kinds read only through the accessors. FORBID_OPT_001: box and unbox pairs. XPHASE_001: constants shared between Elm and C++ with no automatic check.

Documents:

- [eco.md](../../THEORY.md): why the models are kept apart.
- [runtime.md](runtime/runtime.md), [garbage-collector.md](runtime/garbage-collector.md), [runtime-data-structures.md](runtime/data-structures.md), [closures-and-calls.md](closures-and-calls.md), [eco-dialect.md](backend/eco-dialect.md), [mlir-generation.md](compiler/mlir-generation.md).
- `plans/hpointer-representation-redesign.md` (the word encoding, D1 to D10); `plans/2-bit-unboxed-migration.md`.

Rows and comments that disagree with the code. A developer who trusts them writes the wrong test or looks for layouts in the wrong phase:

- HEAP_014 and XPHASE_002 say an embedded constant is one whose constant bits are nonzero. False has constant code 0, so that test misclassifies it. The real test is the pointer indicator (REP_CONSTANT_001, REP_CONSTANT_002).
- REP_HEAP_001 says layout metadata is produced during monomorphization, but monomorphization supplies only constructor shapes, and code generation derives every layout.
- REP_AGG_001 says the aggregate types have no producer. Code generation emits `eco.make.tuple2`, `eco.make.tuple3`, `eco.make.custom` and `eco.to_heap` by default.
- REP_SSA_001 lists `i1` among the immediates it says exist only for Int, Float and Char.
- The description of `eco.box` in `Ops.td` says it accepts `i32` and allocates a Bool object. Char is `i16`, and boxing a Bool allocates nothing.
- Comments in `Heap.hpp` describe `ElmArray`'s and `DynRecord`'s unboxed bits as one-bit flags and mention a `Const_EmptyString` constant that does not exist.
