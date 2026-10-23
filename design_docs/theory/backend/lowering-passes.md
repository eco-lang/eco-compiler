# Lowering Passes

The dialect lowers through about twenty small passes because each fact the backend needs becomes decidable at a different point, and each pass sits at the first point where its fact can be decided and where nothing later can make it false. Closures are simplified while they are still single eco operations. The "cannot collect" property of kernels is copied onto calls once every kernel declaration exists. All merging and folding of eco operations happens before the module is prepared for garbage collection, because nothing may be merged or moved after that. Structured loops are turned into branches only after types have been converted. The facts about the whole program (which functions can run, where nursery checks can be hoisted, which functions can never collect) are decided last, on the final LLVM-dialect module, so that the LLVM work after them can run on each partition separately. Each pass writes its result as an attribute, a declaration or a module flag, and the stages after it read that record instead of working the fact out again.

## A fact is decided once, where its inputs are final

Every placement in the pipeline follows one rule: put the pass where everything its fact depends on is complete and still visible, and where no later pass can make the fact false. A pass placed earlier misses inputs that later passes add. A pass placed later finds its inputs already lowered to runtime calls and memory layouts, or runs after a stage that has already relied on the opposite answer. The comments in `EcoPipeline.cpp` and in each pass's header state the reason for each position, and those comments are the first place to look before moving a pass.

The result of each pass is written down, not left for the next pass to rediscover. An analysis that one pass needs and another pass computes leaves a stamp, and the consumer reads the stamp. This is what lets the whole-program facts reach partitions compiled on other threads: a stamp on a function or a flag on the module travels with the code, while an analysis would have to see the whole module again. The whole-program stamps carry the most weight. They are contracts: the backend checks them locally and stops with an error if one is missing or inconsistent.

One function builds the pass list, and every tool that compiles Eco code calls it: the product compiler, the bootstrap compiler, the developer tool and the test JIT. The list is built in three nested layers, each extending the one before, so the developer tool can stop after the first or second layer and print the module at that point. The order, with the validation-build-only passes in brackets:

```text
buildEcoToEcoPipeline:                 # validate and simplify typed eco ops
  RCElimination; [CheckEcoClosureCaptures]; EcoPAPSimplify
  EcoCompareCaseRewrite; UndefinedFunction
buildEcoToOptPipeline:                 # adds structured control flow and the fold slot
  JoinpointNormalization; EcoControlFlowToSCF; EcoListTemplate
  EcoFoldProject (on); CSE (off)       # last point where purity may be used
buildEcoToLLVMPipeline:
  EcoMarkGCLeafCalls; EcoGCPrepare     # strips eco.cse_safe; no merge or motion after
  [EcoGCLivenessAudit]                 # validation only: no eco.cse_safe survives
  BFToLLVM; EcoToLLVM; EcoListCursor; [EcoBoxedStoreVerify]
  EcoTailConversions                   # scf -> cf, then arith + cf -> llvm
  EcoReachability (closed world)       # whole-program tail starts: planners see only live code
  EcoCapHoistPlan
  EcoGcFreePropagation                 # reads eco-cap-covered; last llvm-dialect body rewrite
```

From `runtime/src/codegen/EcoPipeline.cpp` (`buildEcoToEcoPipeline`, `buildEcoToOptPipeline`, `buildEcoToLLVMPipeline`).

Notice the two fences. Garbage collection preparation ends the window in which eco operations may be merged or moved, and gc-free propagation ends the window in which function bodies may be rewritten. Every pass between and around them is placed relative to those two points.

## Checking and simplifying eco operations

The first layer works on eco operations only. Its passes either check something the front end promised or simplify closures and comparisons while they are still visible as one or two operations.

The pipeline opens with a guard against reference-counting operations. The runtime uses a tracing collector, so a reference-counting operation in the input means the front end has a bug, and the pass reports an error and removes nothing. The operations stay in the dialect as an option open for experiments with reuse of memory.

Closure simplification comes next. When a closure that holds some of a function's arguments is created and then immediately given the rest, the pair becomes a direct call, and chains of argument additions fuse into one. This belongs on eco operations because there a saturated closure is a two-operation pattern; after conversion to LLVM it is spread across runtime calls and memory layouts, where it is hard to recognize. The same pass enforces the limit on a closure's arity, the number of parameters it can take.

A comparison whose only use is a case on its result (Elm's `Order`, with `LT`, `EQ` and `GT`) becomes nested boolean cases, which removes both the call and the `Order` value. It runs after closure simplification, so that comparisons made through closures have already become direct calls, and before the declaration check, because it may add a declaration for the three-way comparison kernel and the check must see it.

The layer ends with a check that every directly called function is defined or declared. Inventing a declaration from the first call site of an undeclared function would hide code generation bugs and produce wrong signatures, so the compiler owns every declaration and this pass only validates.

## Structured control flow and the fold slot

The second layer turns Elm's control flow into MLIR's structured control flow, whose if, switch and while operations hold their branches as nested regions that yield values. That form fits Elm, where a case is an expression: each eco case alternative ends by yielding a value and maps directly onto a value-producing if or switch. The tail-recursive loops that the front end writes as join points (labeled continuations that jumps inside the function can target) map onto while loops.

Deciding which join points can become loops is a separate analysis that only stamps an attribute. The rewrite that follows reads the stamp, so the patterns stay small and the analysis exists once. The rewrite runs on top-level operations in parallel chunks, and whatever it leaves unconverted is handled later inside the conversion to LLVM.

Two passes in the pipeline rewrite list loops for chunked lists, which build and walk lists in blocks rather than one cell at a time ([runtime-data-structures.md](../runtime/data-structures.md)); both act only when the module asks for chunked lists. The builder rewrites a loop that conses up a list into chunk builds on a scratch stack. It needs the while loops the previous pass creates, so it runs after it, and it runs before collector preparation so the calls it adds are prepared like any other call. Its partner, which rewrites list-walking loops into a node-and-index cursor, runs after conversion to LLVM: by then projections have become marker calls, so the per-step operations it creates need no preparation.

The fold slot removes redundant work while purity is still known. A field projection or a tag read from a construct built earlier in the same function folds to the original operand or the constant tag. MLIR's common subexpression elimination has its place in this slot and is off by default. Merging identical constructs keeps memory alive longer, and it changes results: two constructions that each contain a NaN are separate objects, and the equality kernel answers True when both sides are the same object, so merging them turns a False comparison into True. The folder stays on because it deletes operations without merging allocations. A canonicalizer has no place in the slot, since LLVM canonicalizes the code again after translation.

The fold slot sits before collector preparation because preparation strips the purity attribute that merging relies on.

## Preparing for the collector and converting to LLVM

The third layer prepares the module for the collector and then converts it to LLVM's dialect.

It starts by copying the "cannot collect" fact from each kernel declaration onto every direct call to that kernel, as an attribute on the call. This runs here because by this point every pass that can add a kernel declaration or a call has run. The fact sits on the call, not only on the declaration, because preparation runs separately on each function and cannot look at sibling declarations. Inside preparation the fact is read only by the merge census, an optional report that counts how often a later allocation could move above a call to join an earlier group.

### What garbage collection preparation does and does not do

Garbage collection preparation (`EcoGCPrepare`) does not decide what the collector sees, although its name suggests it does. Statepoint rewriting in LLVM computes the roots from which heap pointers are live, as the parent document describes, and the compiler supplies none. Preparation computes no root sets and attaches no root operands, and the allocation emitter builds its call from the arguments alone:

```cpp
Value eco::detail::emitAllocWithSafepoint(
    Operation *op,
    ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    LLVM::LLVMFuncOp allocFunc,
    ValueRange args) {
    // RS4GC handles safepoint insertion automatically — no marker needed.
    auto allocCall = rewriter.create<LLVM::CallOp>(op->getLoc(), allocFunc, args);
    return allocCall.getResult();
}
```

From `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`.

A garbage collection bug therefore cannot be fixed in preparation; it has to be fixed where statepoint rewriting gets its information, in the types, the "cannot collect" attributes or the fold-proof casts.

Preparation has three effects, and they are why it keeps its place.

1. It groups allocations, so that one request to the nursery can serve several objects.
2. It strips the purity attribute from calls. After that MLIR treats every call as having unknown effects, which ends any merging or motion of calls.
3. It is the fence. The rule that every consumer of purity runs before preparation is written in the pipeline source, and every merge, fold or move of eco operations belongs on the near side of it.

A group asks the nursery once for space for all its members, through a fast path and a slow path that may collect, and then initializes each member in place. A run in which every member has an inline bump allocation is split back into single allocations, because a group costs an out-of-line call plus one initialization call per member while a single allocation bumps the nursery pointer with no call. Capacity hoisting can also cover a straight-line run of single allocations with one check, while a group's out-of-line call ends the hoisted headroom. In practice only mixed runs, such as those containing a string allocation, stay grouped.

The allocation sizes that grouping uses come from a table that must equal the runtime's own size calculation, and compile-time assertions in the heap lowering check that the layout constants agree with the runtime's heap header.

### One conversion pass, staged for parallelism

After the byte-sequence dialect of [bytes-fusion.md](../compiler/bytes-fusion.md) is lowered, touching only the functions that contain its operations, the conversion to LLVM's dialect does the bulk of the lowering. It is one pass with internal stages, split into source files by concern, so that it can convert function bodies in parallel without locks.

1. Allocation groups become their fast, slow and merge blocks.
2. Every function signature becomes an LLVM function shell and every module-level global is lowered, serially or in shards.
3. Every module-level artifact a body might need is created in advance: runtime declarations, string globals, closure wrappers and layouts. Then the symbol cache is frozen. [closures-and-calls.md](../closures-and-calls.md) describes the wrappers and how closure calls lower.
4. Function bodies are converted in parallel chunks that only read shared state.
5. A closing step attaches the collector strategy to each function, adds guards to top-level constants that are computed on first use, builds the global initializer, and strips declarations nothing uses.

Step 3 is what makes step 4 safe: a body conversion that needed to create a declaration would have to write to the module from many threads. Structured control flow leaves the pass intact, with its types converted.

## Finishing bodies, then deciding whole-program facts

The rest of the third layer finishes the function bodies and then computes the facts that need the whole program.

The tail conversions lower structured control flow to plain branches between blocks, then arithmetic and branches to LLVM's dialect, then reconcile leftover casts, per function and in parallel chunks. Structured control flow is lowered only at this point, after type conversion, so the values a while loop carries are already LLVM types when the branches create block arguments for them, and no block argument ever carries the boxed eco type. It is one pass rather than MLIR's three upstream conversions because those rebuild a type converter and pattern set for every function and lower branches serially. A version that fuses all three lowerings into one conversion corrupts memory even on a single thread, so the lowering to branches is a separate step inside the pass, with all state scoped to a chunk.

Three planning passes then run on the final LLVM-dialect module, so they see every call the pipeline has created. They run in this order.

1. Reachability, for closed-world outputs only, removes every function nothing can call, makes the rest internal and sets a module flag. A closed world is safe to assume because an executable exposes only its entry point and the global initializer.
2. The capacity plan decides where a callee's nursery capacity check can move into its caller, stamps the decision on each function and sets a module flag.
3. Gc-free propagation stamps every function that provably cannot reach a collection as a leaf and sets a module flag. Statepoint rewriting skips calls to stamped functions.

The order carries weight. Reachability goes first so the planners see only live functions. The capacity plan goes before gc-free propagation because the latter reads which calls the plan covers. Gc-free propagation goes last and must be the last pass that changes LLVM-dialect bodies: a later rewrite could add a collecting call to a function already stamped as a leaf, and no check on a single partition would notice.

The planners run in MLIR, not in LLVM, because an MLIR context can be shared between threads and an LLVM context cannot. Splitting the module before translation is possible only if no step on the LLVM side needs the whole program, so every whole-program decision has to be made here. LLVM-side versions of the three analyses exist as validation twins that recompute each answer for comparison, and as fallbacks for builds that turn the MLIR versions off. The planners and the native splitter derive symbol edges from one shared definition of the symbol graph, and the planners and the backend read one table of which marker calls may collect, so that every consumer gets the answer the planners got.

### Handing the facts to the partitions

The planners' results reach each partition as function attributes and string module flags on the final module. The splitter checks them as they cross a partition boundary, and the backend checks each function against them again before it relies on them, so a missing or stale stamp stops the build instead of producing a wrong stack map. [native-drivers.md](native-drivers.md) describes the split and these checks.

Statepoints are not made in this pipeline. LLVM's statepoint rewriting runs after translation and before the optimizer, on each partition or on the whole module when it is not split. The pipeline's part is to hand it code it can reason about: every boxed value as a pointer in the garbage-collected address space, conversions between those pointers and integers written as barrier calls that the inliner cannot fold, and leaf stamps it can trust. The barrier calls are replaced with plain casts strictly after statepoint rewriting.

## Parallel without changing the output

The lowered program is very many tiny functions, and most of the pass boundaries that are not set by a fact are set by keeping that work parallel. Each parallel stage hands out functions in chunks, not one at a time, because MLIR's per-element parallel loop takes the diagnostic handler's lock for every element and serializes the thread pool. The folder is a module pass that processes functions in chunks, because tens of thousands of nested per-function runs serialize on the lock in MLIR's pass instrumentation. Each stage keeps its mutable state per chunk and falls back to serial work when threading is off.

Every parallel stage must produce output byte-identical to the serial path. The native bootstrap reaches its fixed point by comparing the bytes of successive compilers, so a stage whose output depends on thread scheduling breaks the bootstrap even when its code is correct. That is why, for example, the conversion sorts the evaluation layouts it creates before emitting them.

## Checks that never repair

Several passes check and never fix: the reference-counting guard, the declaration check, the closure-capture check, the purity audit after collector preparation, the stale-pointer check before boxed stores, and the backend's pointer-to-integer check. Each failure points to a bug in the front end, and a pass that repaired its input would hide that bug and produce code nobody intended. The closure-capture check, the purity audit, the stale-pointer check and the pointer-to-integer check are compiled in only for validation builds, and release builds also skip the verifier between passes. Keeping validation in passes of its own is what makes removing it from release builds free. Most transforms can also be turned off one at a time by an environment switch, so a miscompile can be bisected on an existing MLIR file without recompiling the Elm side.

## What the pipeline trusts

The pipeline is correct only if the things around it hold.

- The front end emits well-formed eco operations. Case alternatives end in a yield, every called symbol is declared, kernel declarations carry their calling conventions and, where eligible, the "cannot collect" attribute, and the slot kinds of a construct match its operands' types. The passes repair none of this; case result types, for example, come from the front end and are never inferred.
- The eco dialect's verifiers and interfaces, such as the memory effects of calls and the pure traits on operations, behave as [eco-dialect.md](eco-dialect.md) describes.
- The heap layout constants and size table agree with the runtime, as checked above.
- Elm values never change once built, so no old object points to a younger one and the lowering emits no write barriers.
- The backend after the pipeline treats the whole-program stamps as contracts and fails on missing or stale ones.

## Changing the pipeline

A change fits when it decides its fact where the inputs are final, records the fact where later stages can read it, keeps every merge or motion of eco operations before collector preparation, and keeps every whole-program decision in MLIR.

### Examples of changes that fit the theory
- An eco-level simplification that removes an allocation or a call becomes a small pass in the first layer or the fold slot, before collector preparation, with its own environment switch and a text-matching test of the pass output. The comparison rewrite and the folder are built like this.
- A fact a later stage needs is computed where its inputs are final, stamped on the operation, function or module, and given a validation twin that recomputes it. The "cannot collect" call marking and the three planners have this shape.
- An operation family adds patterns to the conversion's source file for its concern and creates any module-level artifact it needs in the pre-creation stage, so parallel body conversion stays read-only.
- Raising a representation limit, such as closure arity or the number of object fields, changes closure simplification, the closure, heap and aggregate lowerings, the grouping size table and the heap invariants together, because each of them encodes the limit.
- A parallel stage hands out work in chunks, builds converters and patterns once per chunk, and is checked for output byte-identical to the serial path.

### Examples of changes that would break the theory
- Merging, eliminating or moving eco operations after collector preparation. Purity is gone by then and the attached lists and group membership go stale. Put the transform at the fold slot, and do not merge allocations unless their result provably cannot reach a Float.
- Fixing a collector bug by adding values to preparation's live sets, or reading them as the source of collector safety. The emitted code never uses them. Fix what statepoint rewriting sees: types, "cannot collect" attributes or fold-proof casts.
- Rewriting LLVM-dialect bodies after gc-free propagation, or between the capacity plan and gc-free propagation. A stamp goes stale in a way no check on one partition sees. Put the rewrite before reachability.
- Looking up a callee's declaration inside a per-function pass or a consumer to recover a fact about it. A per-function pass cannot see sibling declarations, and two consumers that look the fact up differently diverge. Copy the fact onto the call.
- Making a validator repair its input, for example by stubbing a missing declaration. It hides the front-end bug; fix the emitter in the Elm compiler.
- Emitting a raw integer-to-pointer or pointer-to-integer cast for a boxed slot. The inliner can fold it and leave an integer live across a statepoint. Use the slot helpers, which emit the barrier form.
- Adding a whole-module analysis on the LLVM side. It cannot run on a partition. Compute it in the MLIR tail and stamp it.
- Creating a declaration or global from inside parallel body conversion. It writes shared state from many threads; create it in the pre-creation stage.

## References

Parent: [backend.md](backend.md). Siblings: [eco-dialect.md](eco-dialect.md), [native-drivers.md](native-drivers.md).

Code:

- `runtime/src/codegen/EcoPipeline.cpp`, `runtime/src/codegen/EcoPipeline.h`: the three builders, the ordering comments, the purity rule, `ecoMlirCseEnabled`.
- First layer, in `runtime/src/codegen/Passes/`: `RCElimination`, `CheckEcoClosureCaptures`, `EcoPAPSimplify.cpp`, `EcoCompareCaseRewrite.cpp`, `UndefinedFunction`.
- Second layer: `JoinpointNormalization`, `EcoControlFlowToSCF.cpp`, `EcoListTemplate`, `EcoFoldProject.cpp`.
- Third layer: `EcoMarkGCLeafCalls.cpp`, `EcoGCPrepare.cpp`, `EcoGCLivenessAudit` (validation builds: checks that no `eco.cse_safe` survives preparation), `BFToLLVM`, `EcoToLLVM.cpp`, `EcoToLLVMInternal.h`, `EcoToLLVMHeap.cpp` (`lowerAllocGroups`), `EcoToLLVMRuntime.cpp` (`emitAllocWithSafepoint`), `EcoToLLVMClosures.cpp`, `EcoToLLVMControlFlow.cpp`.
- Tail: `EcoListCursor.cpp`, `EcoBoxedStoreVerify`, `EcoTailConversions.cpp`, `EcoReachability.cpp`, `EcoCapHoistPlan.cpp`, `EcoGcFreePropagation.cpp`.
- Shared machinery: `Passes/EcoParallel.h` (`forEachChunk`), `Passes/EcoSymbolGraph.h`, `Passes/EcoMarkerFacts.h`, `EcoCapHoistCore`; `runtime/src/codegen/LoweringStats.cpp` (per-pass timing); `runtime/src/codegen/RuntimeSymbols.cpp` (runtime symbols for the JIT).
- LLVM-side collector contract: `Passes/EcoGCStrategy.cpp`, `Passes/EcoSlotCastBarriers.h`, `Passes/EcoPtrIntVerify.cpp` (`addEcoGCPipeline`, `StripEcoCastBarriers`).
- `runtime/src/codegen/Passes.h`: pass declarations. Several are stale: per-family lowering passes are declared but never defined (the conversion is one pass), and some comments describe older types, anchors and gates.

Invariants (`design_docs/invariants.csv`):

- CGEN_011: every callee declared.
- CGEN_028, CGEN_053: case alternatives end in a yield.
- CGEN_049: slot kinds match operand types.
- CGEN_072, CGEN_074, CGEN_081, CGEN_083: the whole-program stamps.
- CGEN_077: collector preparation, leaf calls and allocation grouping.
- REP_LLVM_002: boxed-slot casts.
- HEAP_005: no old-to-young pointers.

Design documents: `design_docs/mlir-level-partitioning-whole-program-steps.md`.
