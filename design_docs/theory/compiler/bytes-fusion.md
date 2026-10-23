# Bytes fusion

Bytes fusion compiles a call to `Bytes.Encode.encode` or `Bytes.Decode.decode` into code that writes or reads the buffer directly, whenever MLIR generation can read the encoder's or decoder's shape from the program after inlining. A fused encoder works out the exact size of its output, allocates one buffer of that size and writes each value through a cursor, in order. A fused decoder checks that enough bytes remain before each read and produces `Nothing` as soon as a check fails. The fused code is written in a small dialect of its own, `bf`, built around that cursor, and is lowered to loads, stores and calls to runtime helpers. When part of an encoder cannot be read, that part is built as an ordinary `Encoder` value and written into the same buffer by the kernel's own walker. When nothing in an encoder can be read, or a decoder cannot be read whole, the call stays a plain call to the C++ kernel that implements elm/bytes. That fallback is always correct, because the kernel is the reference for what elm/bytes means.

## The kernel is the reference

Fusion is an optimization that takes its correctness from the kernel. It replaces a call only when the structure it has read describes the whole encoder or decoder, and the call it replaces is the kernel call that implements elm/bytes. Every case it does not recognize therefore already has a correct answer: leave the call alone. The cost of a missed shape is speed, never a wrong result.

The speed is worth having because the kernel interprets. On the kernel path an encoder is a tree of values, one per combinator, which the kernel walks once to find its size and again to write the bytes, and a decoder is interpreted the same way. Fused code builds no tree and writes each byte straight from the values the program already holds.

Partial fusion of encoders keeps the kernel as the reference. A part the compiler cannot read is handed to the same walker the kernel uses, sized by the same function, so the bytes agree with the kernel's byte for byte. Decoders have no partial form, because there is no way to hand the middle of a decode to the kernel and carry on, so a decoder fuses whole or not at all. Elm values are immutable and Elm expressions have no effects, which is what lets the fused code compile a value expression at a different point from the source, or twice, and get the same value.

## Where fusion runs

Fusion is a fast path inside MLIR generation, run on the final graph after the post-monomorphization inliner. Every saturated call first passes a gate that tries encoder fusion before the ordinary call path. Decoder fusion is tried in two places: on a saturated `decode` call, and on the shape an inlined `decode` leaves behind, a `let` that destructures a value and then calls the kernel. MLIR generation is the place where a call can be replaced by a specialized emission without adding a way to recognize kernel calls to monomorphization, and after inlining is the point where the program's helpers have been unfolded into shapes that can be read. How the specialized emitters sit on the core generator is described in [mlir-generation.md](mlir-generation.md).

Inlining cooperates by unfolding helpers, not by being matched. The inliner always inlines a fixed list of functions: the elm/bytes primitives and combinators and the compiler's own bytes helpers, so that those helpers dissolve into elm/bytes calls, list literals, `::` and `List.map`, which the recognizer can read. `encode` and `decode` are kept off that list, because inlining them would replace them with the kernel call and leave nothing to fuse. Keeping them off the list does not stop the cost-based inliner from inlining the one-line `encode` wrapper. A list of functions the inliner must never inline is not used, because putting the two entry points on one crashes a stage of the self-compilation chain. Fusion instead also recognizes the inlined kernel form of each entry. The limit on how much the inliner may inline into one function is set high, at 1000 by default, because a whole serializer unfolds dozens to over a hundred helpers, and a lower limit stops the unfolding before a shape that can fuse appears. For the same reason the eta-expansion before monomorphization skips aliases of the encoder's constructors such as `unsignedInt8 = U8`, since expanding them hides the constructor from the recognizer.

The recognizer matches elm/bytes by name and nothing else. It accepts globals whose home is package `elm/bytes`, module `Bytes.Encode` or `Bytes.Decode`, by function name, plus the constructor names of the `Encoder` type that appear after inlining and the two endianness constructors. It looks through curried calls, `let` bindings and local variables bound earlier. It never matches a project's own helper names, so a user program's helpers are treated exactly as the compiler's own are: reached through inlining or not at all. Recognition looks up each specialization's home in the specialization registry, so an elm/bytes that was renamed or re-exported would stop fusing.

## Three stages

Fusion runs in three stages over three modules. The first, in `Reify`, reads an expression and returns the encoder as a list of nodes or the decoder as a tree, or returns nothing. The second, also in `Reify`, flattens that structure into a short list of cursor operations, a small form whose types `LoopIR` defines. The third, `Emit`, turns the operations into `bf` operations, structured control flow and a few eco operations. The values inside the operations, such as the integer to write, a length or the function given to `map`, stay as unlowered Elm expressions until emission compiles them through a callback into the ordinary expression generator, so the emitter never depends on the expression generator's module.

The middle form exists to separate what the shape is from how it is emitted. It holds no pointers and no MLIR, so recognition can be tested without MLIR, and emission does not depend on the patterns of the program graph. Sizes have a small type of their own in it, so that terms known at compile time and terms known only at run time can be mixed and the constants folded together.

The encoder node type is the whole vocabulary an encoder can be read into:

```elm
type EncoderNode
    = EU8 Mono.MonoExpr
    | EU16 Endianness Mono.MonoExpr
    | EU32 Endianness Mono.MonoExpr
    | EF32 Endianness Mono.MonoExpr
    | EF64 Endianness Mono.MonoExpr
    | EBytes Mono.MonoExpr
    | EUtf8 Mono.MonoExpr
    | ELoop
        { itemVar : String
        , itemType : Mono.MonoType
        , itemNodes : List EncoderNode
        , iterExpr : Mono.MonoExpr
        , countExpr : Mono.MonoExpr
        }
    | EOpaque Mono.MonoExpr
```

From `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm`. Notice that every leaf holds an expression: only the structure is read, never the values. Signed and unsigned writes of the same width share one node, because they write the same bytes. The loop carries the element's type so that emission can read each list element at its real type; without it, a loop over records reads its elements at the wrong type. `EOpaque` is the leaf for a part that could not be read.

## Encoders: size first, then one buffer

An encoder fuses from fixed-width writes of integers and floats, copies of a `Bytes` value, UTF-8 strings, `sequence` of a literal list (flattened in order), and one list loop. The loop is the idiom `sequence (unsignedInt32 e (List.length xs) :: List.map f xs)`, in which `f` is a lambda of one parameter, or a named function that is not recursive and is found in the inliner's table of bodies, and whose body reads as fixed-width writes only. A helper that was eta-expanded with one extra trailing parameter is reduced back first. Any other subtree becomes an opaque leaf.

Before allocating, the fused code computes the exact size of the output. Fixed-width writes contribute constants, which are folded. Each part whose width varies adds one term computed at run time: the UTF-8 width of a string, the length of a `Bytes` value, the list length times the item width for the loop, and the walker's size for an opaque leaf. The loop's `List.length` is taken from its header write, so it is computed once. Then one allocation gives a buffer of exactly that size, and a cursor is placed at its start. Knowing the size first gives one buffer, no growth and no copying, and it is why writes need no bounds checks: every write was counted in the size, so a write past the end cannot happen unless a write was left out of the count.

Emission threads one cursor through the writes in source order. The loop becomes a while loop over the list that carries the cursor and the remaining list, reads each head at the element's type and binds the function's parameter to it. Integer writes take a 64-bit integer and float writes a 64-bit float, and a value that arrives boxed is unboxed first.

An opaque leaf is compiled as an ordinary `Encoder` value, sized by one operation and written at the cursor by another. Both are thin wrappers over the kernel's own size and write walkers, which already take a destination buffer and an offset, and neither allocates. Without the leaf, one subtree the compiler cannot read, typically a function parameter used as the per-element encoder, would send the whole encoder back to the kernel and lose all of its fixed-width writes. With it, only that subtree goes to the walker and everything else stays fused, in one buffer that agrees with the kernel's output. An encoder that reads as nothing but a single opaque leaf is left as a kernel call, because an allocation plus one walk costs strictly more than calling the kernel.

Encoder fusion can be turned off in the project's settings and is on by default; decoder fusion is attempted whatever that setting says, and no reason for the difference is recorded.

## Decoders: whole or not at all

A decoder fuses from fixed-width reads, `bytes n`, `string n`, `succeed`, `fail`, `map` through `map5`, and `andThen` with a lambda of one parameter, with a special case for reading an integer length and then a string or bytes of that length. It also fuses exactly two loop idioms: a count loop starting from `(n, [])` and a sentinel loop starting from `[]` that stops at an integer literal. Each loop reads one fixed-width item per step, accumulates with `::` and finishes with the accumulator or its reverse. A loop fuses only in exactly this form because the fused code must provably compute what the loop computes; a looser match that ignores the finishing idiom or the elm/bytes argument order cannot promise that. Any part the compiler does not recognize makes the whole decoder unreadable, and the call goes to the kernel.

Each read is guarded by its own bounds check, and failure is a branch. The shape of one fused read is:

```
%ok = bf.require %cur, N
%r  = scf.if %ok -> !eco.value {
        %v, %cur2 = bf.read.* %cur
        ... the rest of the decoder on %cur2 ...
        scf.yield %inner
      } else {
        %nothing = eco.constant Nothing
        scf.yield %nothing
      }
```

From the documentation of `emitDecoderOpsNested` in `Emit.elm`. Notice that the read happens only inside the branch where the check passed, and that the rest of the decoder nests inside it, so the nesting is as deep as the number of reads. The failure branch yields the embedded `Nothing` constant: it throws nothing and allocates nothing. `fail` yields `Nothing` and drops the rest of its branch. A `map` applies its function to the values read, `succeed v` compiles `v`, and the final value is wrapped in `Just`. A count loop checks `count * width` bytes once before it starts, with a guard against overflow in the multiplication, which is valid because every item has the same width. A sentinel loop does not know its length, so it checks before each item.

The fused code and the kernel must agree on failure, and they do: both give `Nothing` for the whole decode on any failing read, both use the same strict UTF-8 validator, and neither requires the input to be consumed fully. They get there differently. The kernel's decode interpreter throws from the failing read or `fail` and catches the exception at the top of the decode, where it restores the root stacks and returns `Nothing`; it uses an exception because the stock elm/bytes combinators destructure an offset-and-value pair immediately and have no failure case to branch on. The kernel side is described in [elm-kernel.md](../kernels/elm-kernel.md). The fused code has no combinators, so it can branch.

Fewer decoders reach the recognizer than its patterns cover. A decoder that takes arguments, such as `unsignedInt16 LE`, `float64 BE` or `string n`, has already been inlined into a decoder wrapped around a kernel read by the time MLIR generation runs, and the recognizer does not read that form, so it does not fuse. Decoders with no arguments, such as `unsignedInt8`, stay as named globals and do fuse.

## The bf dialect

The `bf` dialect is the language fused code is written in. Its one type, `!bf.cursor`, is a position in a buffer, held as a pair of plain pointers: the current position and the end of the buffer. Every read or write takes a cursor and returns the advanced one, so the order of the accesses is explicit in the data flow and the emitter threads a single cursor through them. Its 26 operations allocate a buffer and place a cursor in it, read and write fixed-width values, copy bytes and UTF-8 strings, compute the run-time widths that an encoder's size needs, check bounds, and hand an opaque `Encoder` value to the kernel's walker for sizing and writing. All of them are declared in one TableGen file.

Reads are unchecked loads. A bounds check operation, `bf.require`, says whether a given number of bytes remain, and every read must sit inside a region that a passing check dominates. Separating the check from the read lets one check cover many reads, as the count loop's does, and lets the emitter decide where the failure branch goes. The dialect has no hand-written verifiers, so the rule that every read follows a passing check is kept by the emitter, and nothing in the dialect checks it.

Generated code never computes an address inside a buffer or string header. It calls runtime helpers for a buffer's length and data pointer, a string's UTF-8 width and its copy into the buffer, strict UTF-8 decoding (which returns null on invalid input), and allocating a buffer. A byte buffer has flat, large-header and slice forms, and a string has UTF-16, rope, slice and UTF-8 forms. Because only the helpers know them, adding a form changes only the helpers. How those values are stored is described in [runtime-data-structures.md](../runtime/data-structures.md).

A lowering pass of its own, `BFToLLVM`, turns the operations into loads, stores, byte swaps and calls to those helpers; where it runs among the other passes is described in [lowering-passes.md](../backend/lowering-passes.md). The hand-written MLIR fixtures that pin each operation's lowering are described in [codegen-tests.md](../verification/codegen-tests.md).

The dialect is separate from eco so that the eco dialect stays stable and byte fusion can be switched on or off without touching it. The cursor type stays private to `bf`, and its lowering is one pass rather than patterns mixed into the eco lowering. The emitter gives every heap operand of a `bf` operation eco's boxed value type, so the two dialects meet only at heap values. The operations themselves declare those operands as any type, so nothing in `bf` enforces this. The eco dialect itself is described in [eco-dialect.md](../backend/eco-dialect.md).

## The cursor and the collector

As the code stands, fused code is not safe against garbage collection when its buffer is in the nursery. This is a defect of the code, not a property of the design. It follows from three facts. The cursor lowers to plain pointers in LLVM's default address space, and the statepoint rewriting that relocates pointers across a collection only tracks pointers in the collector's address space, so a cursor is never updated when its buffer moves. A buffer smaller than 8 KiB is allocated in the nursery, which a minor collection copies, while a larger one keeps its bytes in the large-object space, which does not move ([garbage-collector.md](../runtime/garbage-collector.md)). And fused code allocates while a cursor is live, so a collection can run at those points and leave the cursor pointing into the nursery space the buffer was copied out of. The helper header itself warns that a buffer's data pointer does not survive a collection.

The cases in which fused code allocates with a live cursor all occur:

- Reading a `Bytes` value allocates the result and then copies from the old cursor pointer.
- A decode loop builds a list cell for each item while the read cursor is live, and `map` results are built the same way.
- Strict UTF-8 decoding allocates the string and then reads its source bytes.
- An encoder compiles the values it writes, and any opaque subtree, after the cursor is set up, and any of those expressions may allocate.

The helpers that size and write an opaque encoder do not allocate, and the argument that the opaque leaf is safe rests on that, but nothing in the code marks or checks them as helpers that cannot collect. A stress test of fused count loops over 8,000-byte nursery buffers passes. Its count of about 700 minor collections assumes a small nursery set through the heap configuration, which the test runner does not set. A pass shows only that the hazard did not show up in that test; it is not evidence that the code is safe.

A fix must give the fused region one of these properties, and this document does not choose among them:

- the buffer does not move while any cursor into it is live;
- nothing allocates, and so no collection can run, while a cursor is live;
- the cursor's pointers are derived again from the buffer, held as a value the collector tracks, after every point that may allocate.

Until one of them holds, any change to fusion should be checked against the list of allocation points above, and should not add to it.

## Where the code and its stated rules disagree

The UTF-8 and bytes reads return a success flag that the emitter discards. The UTF-8 read reports failure on invalid input, and the lowering computes the flag, but the emitter branches only on the bounds check. A fused decode of invalid UTF-8 would therefore produce `Just` of a null string where the kernel produces `Nothing`. This is latent, because string decoders do not reach fusion in practice, and the fixture for the operation tests the flag itself, not the emitter's use of it.

Three numbered rules are false for an encoder with an opaque leaf. One says fusion is all or nothing for encoders as well as decoders, which the opaque leaf makes false. The other two say a fused encoder makes no intermediate allocations and calls no interpreter, and an opaque leaf builds an `Encoder` value and runs the kernel's walker. The References list gives their identifiers.

The emitter compiles the expression of a string, a `Bytes` value or an opaque leaf twice, once for the size term and once for the write, so the string or the `Encoder` value is built twice. A comment calls this the same two passes the kernel makes, which understates it for an opaque leaf.

## Examples of changes that fit the theory

- Another elm/bytes primitive or combinator: a node in `Reify`, an operation in the middle form, an emitter case, a `bf` operation with a runtime helper for any layout detail, and a lowering pattern in `BFToLLVM`. The opaque leaf follows exactly this path.
- Another shape that inlining produces: teach the recognizer to look through it, as it looks through `let` bindings, local variables and eta-expanded helpers, rather than naming the helper that produced it.
- Carrying a fact from recognition to emission: put it in the node, as the loop's element type is carried, rather than working it out again in the emitter.
- Another buffer or string representation: change only the runtime helpers. Buffer slices and the UTF-8 string forms are handled this way, in the helpers alone.
- More decoders fusing: extend the decoder recognizer to read the inlined form of a decoder that takes arguments, a decoder around a kernel read, as the loop recognizer already reads inlined `succeed`, `map` and `andThen`.
- Making the fused code safe against the collector by any of the three properties in the section on the cursor and the collector, applied to every allocation point listed there.

## Examples of changes that would break the theory

- Fusing a decoder that is only partly recognized by guessing the rest. Fused code that only approximates the source breaks the rule that fusion computes exactly what the kernel computes. Leave the decoder to the kernel, or add an exact pattern.
- Matching a project helper by name, such as the compiler's own list encoder. It ties the compiler to one codebase. Add the helper to the inliner's list and match what it unfolds into.
- Adding `encode` or `decode` to the inliner's list. The entry points disappear into kernel calls and nothing fuses.
- Reading a buffer or string header from generated code, for example computing the address of a length field. It ties generated code to one representation. Add or extend a runtime helper instead.
- An unchecked read that no passing bounds check dominates, or a write whose bytes were not counted in the size. Either one reads or writes past the buffer. Give every read a check and every write a size term.
- A fused failure path that traps or throws. The kernel returns `Nothing`, and the fused code must return the same. Branch to the `Nothing` constant.
- Adding a fused operation that allocates while a cursor is live, such as a read that builds its result on the heap and then continues reading through the same cursor, or making a helper called with a live cursor allocate, such as the opaque encoder's walker or the UTF-8 copy. Each one adds a point where a minor collection can move a nursery buffer under a cursor that is never updated. Keep allocation out of the region where a cursor is live, or make the change together with a fix that gives the region one of the three properties above.

## References

Parent: [compiler.md](compiler.md). This node has no children.

Related documents: [mlir-generation.md](mlir-generation.md) (the emitter layering), [lowering-passes.md](../backend/lowering-passes.md) (`BFToLLVM`), [eco-dialect.md](../backend/eco-dialect.md) (the eco dialect), [elm-kernel.md](../kernels/elm-kernel.md) (the kernel encoder and decode interpreter), [runtime-data-structures.md](../runtime/data-structures.md) (buffer and string forms), [garbage-collector.md](../runtime/garbage-collector.md) (the nursery and the large-object space), [codegen-tests.md](../verification/codegen-tests.md) (the `bf` fixtures).

Code:

- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm`: recognition, the node types (`EncoderNode`, `DecoderNode`), `reifyEncoderWith`, `reifyEncoderHelp`, `reifyLoop`, and conversion to the middle form (`nodesToOps`, `decoderNodeToOps`).
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm`: the operation and width types (`Op`, `DecoderOp`, `WidthExpr`, `simplifyWidth`).
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Emit.elm`: emission to `bf` and `scf` (`emitDecoderOpsNested`, `addNodeWidth`).
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`: `generateSaturatedCallFusionGate`, `tryBytesEncodeFusion`, `tryEncoderFusionWithBindings`, `tryInlinedDecodeFusion`, `bfExprCompiler`, and the kernel fallbacks in `generateSaturatedCallNoFusion`.
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`: `defaultWhitelist`, `buildBodyLookup`.
- `compiler/src/Compiler/Eco/Config.elm`: `BytesFusionConfig` (`bytesFusion.enabled`, hash token `bf=`).
- `runtime/src/codegen/BF/BFOps.td`: the dialect and `!bf.cursor`; `runtime/src/codegen/BF/`: `BFToLLVM`.
- `runtime/src/allocator/ElmBytesRuntime.h`, `runtime/src/allocator/ElmBytesRuntime.cpp`: the helper interface (`elm_alloc_bytebuffer`, `elm_utf8_decode`, the buffer and UTF-8 helpers).
- `elm-kernel-cpp/src/bytes/BytesExports.cpp`: `elm_encoder_size`, `elm_encoder_write_into`, and the kernel `Elm_Kernel_Bytes_encode` and `Elm_Kernel_Bytes_decode` used as the fallback.
- `test/elm-bytes/src/` (for example `FusionPartialOpaqueTest`, `BytesLoopFusionShapesTest`, `DecodeFailureInCombinatorTest`, `DecodeStringStrictFusedTest`, `BytesLoopFusionGcStressTest`), pinned with `CHECK-MLIR` where fusion must fire; `test/bf-codegen/` for the dialect.

Invariants (`design_docs/invariants.csv`):

- BFUSE_004, BFOPS_018: fusion replaces a call only when the structure describes the whole encoder or decoder.
- BFOPS_006, BFOPS_007, BFOPS_010: exact width and one allocation.
- BFOPS_012, BFOPS_029: no load without a passing check. BFOPS_016, BFOPS_017: failure is a branch to `Nothing`.
- BFOPS_030, BFOPS_032: layout stays in the runtime helpers.
- False for an encoder with an opaque leaf: BFUSE_001 (all or nothing), BFOPS_036 (no intermediate allocations), BFOPS_037 (no interpreter calls). BFOPS_021 cites `BFTypes.td`, which does not exist; the cursor type is in `BFOps.td`.

Design documents:

- `design_docs/fused-bytes-compilation.md`: the plan written before the implementation. Its decisions (a separate dialect, the middle form on the Elm side, interception in `Expr.elm`) match the code; its operation, file and module names do not.
- `plans/bytes-fusion-escape-hatch.md`: the opaque leaf, and the argument that its helpers must not allocate.
