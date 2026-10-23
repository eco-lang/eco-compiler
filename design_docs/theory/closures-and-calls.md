# Closures and calls

Every Elm function value is a closure on the heap, and the closure's header says everything needed to apply it: how many arguments its current stage takes, how many it already holds, how each slot is stored, how its result comes back, and where to find a static descriptor with one uniform entry point. The runtime can therefore apply any closure to any number of arguments without knowing where the closure came from, and this generic apply is the default for every call through a function value. The compiler groups each closure's parameters into stages and records on every call what it could prove about the callee. Where it proved the callee is one specific closure, the back end calls the closure's body directly. Where it proved how many arguments the closure still needs, the back end calls a runtime entry for that exact case. Where it proved nothing, the call goes to generic apply, often through a fast edge that checks the header first and falls back when the check fails. Every faster path is one the compiler may decline, because generic apply is always correct.

## Generic apply is always correct

Elm functions are curried, and Eco applies a closure one stage at a time. A stage is the group of parameters a closure takes in one application: `\x y -> x + y` has one stage of two parameters, while a function of one parameter that returns another lambda has two stages of one. Staging changes how many intermediate closures are built on the way to a result, never the result itself. [global-optimization.md](compiler/global-optimization.md) chooses the stages.

That fact makes one rule possible. Whatever a call site knows about its callee, the closure carries enough to be applied correctly. Generic apply reads the closure's header, computes how many arguments the current stage still needs, and handles too few, exactly enough and too many from that alone. Too many means saturating this stage and then applying whatever closure the stage returns to the remaining arguments, so the call site never needs to know how the callee is staged.

Because generic apply is always correct, every faster path is an addition, never a requirement. Global optimization can leave a call through a join, a function parameter or an unknown callee generic, and the cost is only speed. The faster paths come in two sorts, and the difference between them matters more than anything else here when changing this code:

- A proven path trusts a fact the compiler recorded and checks nothing at run time. A wrong fact is a silent miscompile.
- A guarded path reads the closure's header, compares it with what the call site knows, and takes generic apply on any mismatch. It cannot miscompile when its precondition fails.

A fact the compiler cannot prove belongs on a guarded path, or nowhere.

## The closure object

A closure is a heap object whose fixed part answers every question generic apply asks. After the ordinary heap header comes one packed word. It holds the number of arguments already applied to this stage, the stage's arity, the kind of the stage's result, and a two-bit kind for each of the first 20 slots, saying whether the slot holds a boxed value or a raw Int, Float or Char. The next word points to the evaluator descriptor. Captured and applied values follow, one 8-byte slot each. Kinds for slots beyond the first 20 live in extension words at the end of the object, so a stage can take up to 2047 parameters while the common case reads only the packed word.

The descriptor is static data. It holds the address of a generic entry that takes its arguments as an array, the stage arity, the result kind, and a table of further entries indexed by argument count. Both structs, trimmed, from `runtime/src/allocator/Heap.hpp`:

```cpp
struct EvaluatorDesc {
    EvalFunction   generic;      // +0   the __closure_wrapper_* address
    ...
    unsigned char  result_kind;  // +17  ParamKind of the wrapper's compiled return
    unsigned short stage_arity;  // +18  P (<= CLOSURE_MAX_ARITY)
    ...
    void*          sat[];        // +24  sat[0..stage_arity] if stage_arity <= SAT_MAX_ARITY, else empty; sat[0] unused
};
...
typedef struct {
    Header header;           // header.size = allocated value slots + K
    u64 n_values   : 11;     // Applied arity: args already captured for this stage (0..2047).
    u64 max_values : 11;     // Stage arity: total args this evaluator expects (0..2047).
    u64 result_kind: 2;      // ParamKind: real C-ABI return kind of `evaluator`
    ...
    u64 unboxed    : 40;     // inline 2-bit kinds for params 0..19
    const EvaluatorDesc* evaluator;   // static descriptor, NOT a heap pointer
    Unboxable values[];      // [0 .. header.size - K) values, then K ext kind words
} Closure;
```

Notice that the remaining arity is `max_values - n_values`, read from the header alone. `evaluator` points to static data, never to code and never into the heap, so the collector never traces it. The slot kinds and the result kind are written once, when the closure is allocated, and they describe every parameter of the stage, whether it is already captured or still to come.

Slot kinds cover every parameter so that the runtime can convert at the boundary. When a closure is extended or saturated, the runtime converts each added argument from the caller's kind to the slot's declared kind. A caller that knows nothing about the callee's representation, such as a C++ kernel passing boxed values or a generic site passing a raw Int, still produces exactly the encoding the body expects. The alternative, merging the caller's kinds into the closure's kinds, lets a boxed argument land in a slot declared raw, and that slot then holds a pointer the collector cannot see.

The result kind lives on the header, not at the call site, because a call site often cannot know it. A site derives a result kind from its static type, and for a staged closure that type describes the inner function rather than the real return. Kernel callers have no static type at all. Reading the result kind from the header lets every entry point call the evaluator with the right return type, and lets kernels apply closures that return raw Ints or Floats with no change on their side.

How boxed values and the pointer word look in general is the subject of [value-representation.md](value-representation.md). For closures, the rule to keep is that Bool is boxed in every slot and at every closure boundary. Only Int, Float and Char are stored raw.

## What the compiler emits

Global optimization regroups every closure's type so that its first stage is exactly the closure's own parameters, then records on every call through a function value one of three call kinds. With known segmentation, the callee's remaining arity and the arities of its later stages are known. With segmentation unknown, the callee's parameter representations are known but not its staging. With generic apply, nothing about the callee is trusted. Where lambda-set analysis proves the callee value is one specific closure instance, global optimization also stamps the call with that instance's fast entry and the layout of its captures, and for closure values a stamp takes precedence over the call kind. [global-optimization.md](compiler/global-optimization.md) explains how these facts are proved, and [lambda-set-specialization.md](compiler/lambda-set-specialization.md) how Eco knows which functions can reach a call.

For each closure with captures, MLIR generation emits two functions. The body goes in `name$cap`, whose parameters are the captures followed by the stage's parameters, all typed. Captures become ordinary typed parameters so that a proven call is a plain typed call that LLVM can inline. The second function, `name$clo`, takes the closure itself and the parameters, projects each capture out of the closure, and calls `$cap`. A closure with no captures produces a single function that plays the role of `$cap`. The compiler emits `$clo` for every capturing closure, and closure creation names it as its function, but nothing in the default lowering calls it.

The descriptor's generic entry is a wrapper the back end generates, `__closure_wrapper_typed_<$cap>`. It loads each slot of an argument array at its declared kind and calls `$cap`. Every closure's evaluator wraps `$cap`, with one wrapper per target and result kind, and these wrappers do all the dispatch between differently typed closures. Lambdas are typed end to end, so captured and applied Ints, Floats and Chars flow raw and there are no wrapper functions in MLIR. A uniform boxed calling convention with a generated partial-application wrapper per closure is the rejected alternative. The back-end wrapper remains only because the runtime's uniform entry takes an array.

Three dialect operations carry closures. `eco.papCreate` creates one: it names the target, the stage arity, the captures and their kinds, and the `$cap` when there are captures. `eco.papCreateGroup` creates a set of mutually recursive closures together. Every application of a function value is an `eco.papExtend`, and the front end never emits an indirect call. An application takes one of two forms:

- A typed application carries the remaining arity the compiler proved for the closure it applies. If the arguments it passes equal that number the call saturates the stage, and otherwise it builds a partial application. A stamped call also carries the fast entry and the capture layout.
- A generic application carries no arity, only its call kind. The two generic kinds differ only in the front end. A segmentation-unknown call boxes its arguments to the callee's known parameter representations. A generic-apply call passes Int, Float and Char raw and converts only Bool to its boxed constant, which allocates nothing.

A call with known stages is emitted as a sequence of applications, one batch of arguments per stage. Only the last batch carries the call's result kind, because every earlier stage returns a closure, and that closure is always boxed.

## Lowering a call

The lowering of `eco.papExtend` in `EcoToLLVMClosures.cpp` turns each kind of fact into a different call, and what it checks at run time follows from how much the compiler proved.

| What the compiler proved | What the call becomes | What is checked at run time |
|---|---|---|
| The callee is one instance, and the call saturates it (stamped) | Load the captures at the stamped types and call `$cap` directly | Nothing |
| The remaining arity, and the call saturates the stage | An argument array with a per-argument layout, passed to `eco_closure_call_saturated` (or its `_eval` form for a raw result), behind a fast edge | The fast edge's guards; the arity only in debug builds |
| The remaining arity, and the call does not saturate | `eco_pap_extend_l` | Only that the arguments do not overflow the stage |
| Only the parameter representations, or nothing | One typed 64-bit argument buffer and a layout, passed to `eco_apply_closure_eval` with the desired result kind, behind a fast edge | Everything, from the header |

The two generic kinds lower identically. The buffer's pointer slots are registered as a root range for the call for two reasons. Converting an argument to a slot's kind inside the runtime can box it, and boxing can collect. And on an over-saturated call the trailing arguments wait in the buffer while the first stage's evaluator runs, and that evaluator can allocate anything. The lowering adds no boxing: it passes raw values with a layout, and the runtime is the one place that boxes them. That keeps the IR free of allocations that exist only to box arguments, and a codegen test pins it.

Calls to `$cap`, from stamped sites, fast-edge entries and wrappers, get a second improvement in the back end. A prepass inlines small `$cap` bodies into their callers, and its timing is what correctness depends on. It runs before statepoint rewriting and then removes its inlining marks, because the pipelines after statepoint rewriting would otherwise inline bodies that by then hold statepoints, and that breaks how moved pointers are relocated. Inlining a body that can call the collector is sound only while the conversions between pointers and integers are kept from being folded until statepoint rewriting. With those barriers switched off, the prepass inlines only bodies that never call the collector.

The fast edge is the guarded path for calls the compiler could not stamp. A generic site knows how many arguments it passes but not how many captures the callee holds, so it cannot call `$cap`. It can call an entry whose signature depends only on what the site knows: the argument count N, the argument kinds and the result kind. Those are the `sat[]` entries in the descriptor, `__closure_sat_<target>_n<N>`, each of which loads the captures in place and calls the typed target with the arguments in registers. The lowering brackets each saturated or generic sequence with markers, and `expandSatMarkers` in `EcoBackend.cpp` turns each bracket into a branch. It reads the packed word and checks that the closure needs exactly N more arguments, that its stage arity is at most 20 so the packed word describes every slot, that its result kind matches the site's, and that the kinds of its remaining slots equal the site's argument kinds. It then checks that `sat[N]` is not null. If every check passes, the call goes to the entry with raw arguments in registers, and skips the argument array, its root range and the runtime's argument splicing. Any failure takes the unchanged generic sequence. The kinds check is what makes passing raw arguments sound.

The fast edge is safe whichever way it goes wrong. Entries are generated only for the signatures some site presents and that the closure's smallest capture count can reach. A missing entry leaves `sat[N]` null and the site takes the generic sequence, and a spare entry only wastes space. Keying entries on N alone generates about four times as many entries as the guards can ever reach. The branch is built at LLVM-IR level because an application can sit inside a single-block region of structured control flow, and closure lowering runs before that control flow becomes branches. Entries stop at stage arity 16, which avoids an LLVM code-selection failure on wide statepoint signatures. An entry whose return type is not the canonical type for its result kind is declined, because the branch's merge would receive a value of the wrong type.

Creating a closure is lowered in two ways. A closure with no captures and a stage arity of at most 20 is interned as one permanent object per wrapper, since a closure that is never mutated can be shared by every execution instead of allocated by each. Any other closure is allocated, by an inline nursery bump or by `eco_alloc_closure_k`. The lowering stores the packed word as one constant, the descriptor address, the captures and the extension words, then fills in captures of the closure itself.

Mutually recursive closures are allocated as one group, because each sibling needs the others' addresses as captures before they exist. The group is allocated in one region, and the captures between siblings are written once every address is known. This needs no write barrier, because the siblings are in the same generation and none of them is visible to the program yet.

## Applying a closure at run time

The runtime's generic apply, `eco_apply_closure_eval` in `RuntimeExports.cpp`, decides everything from the closure's own header. In pseudocode, leaving out rooting, statistics and the null case:

```
apply(closure, args[0..n), argKinds, desiredKind):
    remaining = closure.max_values - closure.n_values
    if n == 0:          return closure
    if n < remaining:   return pap_extend_l(closure, args, argKinds)   -- copies, converts to slot kinds
    if n == remaining:
        buf = closure.values[0..n_values) ++ convert(args, argKinds -> closure slot kinds)
        r   = closure.evaluator.generic(buf) cast by closure.result_kind
        return convert(r, closure.result_kind -> desiredKind)
    -- over-application
    next = closure_call_saturated(closure, args[0..remaining))        -- boxed result: a closure
    return apply(next, args[remaining..n), argKinds[remaining..n), desiredKind)
```

Notice that the over-application branch needs nothing from the caller about how `next` is staged. The saturated branch converts in both directions: the arguments into the slots' declared kinds, and the result from the closure's real kind into the kind the caller asked for.

Extension, `eco_pap_extend_l`, never mutates a closure. It allocates a fresh closure with room for the applied slots only, copies the existing captures and extension words, converts each added argument to its slot's kind, and shares the descriptor. Conversion can box, and boxing can collect, so it happens before the fresh closure is allocated, while only the old closure and the arguments need rooting. Because extension copies, a closure is never written after it is built: a zero-capture closure can be an interned singleton, and every closure stays valid as a published object, the rule the collector rests on.

An extended closure holds only the slots applied so far, because a partial application needs nothing more, and the collector traces exactly the first `n_values` slots of a closure, by their kinds. Scanning by count rather than by object size is also why the nursery's to-space needs no zeroing. How closures are traced is part of [garbage-collector.md](runtime/garbage-collector.md).

The other entries are thin layers over generic apply. Two shims serve callers that want a boxed result or pass only boxed arguments, `eco_apply_closure_typed` and `eco_apply_closure`. `eco_closure_call_saturated` and its `_eval` form are the saturated-only entries that typed lowering uses. For allocation, `eco_alloc_closure_fn` builds a closure around a raw C++ function by interning a descriptor for it, and `eco_alloc_closure_group_l` allocates a mutually recursive group. C++ kernels call closures through these entries, mostly `eco_apply_closure`, and never read the closure layout themselves ([elm-kernel.md](kernels/elm-kernel.md)). Keeping closure application in one runtime routine means the list, string and array kernels cannot drift apart in how they read kinds and build arguments.

## What the design relies on

These are the facts the parts above assume of each other, and nothing at run time checks most of them:

- A typed application's remaining arity is the closure's true remaining arity. A saturated typed call checks it only in debug builds, and a partial one aborts only if it overflows the stage.
- A stamp names the instance the value really is. A stamped call reads no header.
- The packed word and the descriptor layout agree bit for bit across `Heap.hpp`, the packing helper, the fast-edge guard and the interning key. The guard reaches the `sat` table at a fixed offset of 24 bytes.
- Every compiled closure's stage arity equals its descriptor's stage arity. The empty `sat[]` above arity 20 depends on it, and validating builds assert it during extension.
- The kinds the wrapper decodes match the kinds on the header, because both come from the same target signature. The kind derivation aborts rather than default to boxed.
- Code that fills value slots publishes `n_values` with no safepoint between setting the count and filling the slots, because the collector traces exactly that many. The generic field-store helpers must never be used on a closure.

## Code that looks live but is not

Three leftovers in this area look like working paths. A change that wakes one of them breaks the design.

The `$clo` functions are generated for every capturing closure, but the evaluator slot never points to one. It points to a descriptor whose generic entry wraps `$cap`. `$clo` exists only because closure creation names it and the verifier requires a named function to exist. An executable drops it, because nothing reaches it from the entry point. A JIT run, a shared library or an object file without internalization keeps it as dead code.

One arm of the typed saturated lowering, `emitClosureCall`, is taken when an application carries a closure-kind attribute, `_closure_kind`. It loads the evaluator slot and calls it as if it were `$clo(closure, args...)`. Nothing reaches it: the front end puts that attribute only on closure creation, and the dialect simplifier only copies it from an earlier application. If it were reached it would jump into the descriptor, which is data. A comment near it calls it "NOT dead", so it can look like a supported path to revive.

`eco_apply_segmentation_unknown` survives only for a unit test. Both generic kinds lower to `eco_apply_closure_eval`.

## Examples of changes that fit the theory

- Widening the closure arity limit. The packed word and the descriptor grow, extension words carry the extra kinds, and every reader goes through the shared kind accessors. Each optimization declines the arities it cannot serve, such as the fast edge above 16 or 20 and interning above 20, and generic apply serves the rest.
- A further guarded fast path. The fast edge is the model: read the header, compare it with what the site knows, call a specialized entry on a match, and fall through to the unchanged generic sequence otherwise. A path built this way cannot miscompile when its precondition is missed.
- A further raw result path. The result kind is on the header, so a path that returns raw values can arrive in steps, first in the wrappers and then at saturated sites, without changing what any call means.
- A kernel that builds closures. It allocates through `eco_alloc_closure_fn` with its result kind, which interns a descriptor with an empty `sat[]`, and it applies closures through `eco_apply_closure`. No compiler change is needed.
- A further proven call shape. Global optimization adds a stamp or a call fact, MLIR generation emits a typed application with the matching attributes, and the lowering turns it into a direct call. Every site the proof does not cover keeps generic apply. The fast stamp for partial applications of a global has this shape.

## Examples of changes that would break the theory

- Mutating a closure when extending it, or writing a capture after allocation. That breaks interned zero-capture closures, the published-object rule and tracing by `n_values`. Allocate a fresh closure, as `eco_pap_extend_l` does.
- Emitting a remaining arity or a stamp from a type or a guess. Neither is checked at run time, so a wrong claim corrupts silently. Emit a generic application, or add a guarded fast edge.
- Deciding the result kind or the slot kinds at the call site. That breaks kernel callers and staged closures. Read them from the header, and convert at the runtime boundary.
- Boxing arguments in the IR before a generic apply. Pass raw values with a layout and let the runtime convert.
- Storing a raw function address in the evaluator slot. Every runtime path reads that slot as a descriptor. A closure around a bare function gets its own descriptor.
- Reviving the closure-kind arm, or calling `$clo` through the evaluator slot. The call would jump into the descriptor. Route calls that need the whole closure through the descriptor's generic entry or a `sat[]` entry.
- Packing the closure word by hand or reading kind bits directly. Use `packClosureWord`, `closureSlotKind` and `ClosureKinds`, and change every reader of the layout together.
- Adding a `sat[]` entry whose return type is not the canonical type for its result kind. The fast edge's merge would receive a value of the wrong type. Keep declining that case.

## References

Related documents: [eco.md](../../THEORY.md) (parent), [global-optimization.md](compiler/global-optimization.md), [lambda-set-specialization.md](compiler/lambda-set-specialization.md), [mlir-generation.md](compiler/mlir-generation.md), [eco-dialect.md](backend/eco-dialect.md), [lowering-passes.md](backend/lowering-passes.md), [value-representation.md](value-representation.md), [kernels.md](kernels/kernels.md), [elm-kernel.md](kernels/elm-kernel.md), [garbage-collector.md](runtime/garbage-collector.md).

Code:

- `runtime/src/allocator/Heap.hpp`: `Closure`, `EvaluatorDesc`, `EvalParamLayout`, `ClosureKinds` and the closure constants.
- `runtime/src/allocator/RuntimeExports.cpp`, section "Closure Operations": `eco_apply_closure_eval`, `invokeSaturatedTyped`, `spliceArgsForSaturatedCall`, `eco_pap_extend_l`, `eco_closure_call_saturated`, `eco_alloc_closure_k`, `eco_intern_closure0`, `eco_alloc_closure_group_l` and `ecoDescForKernelEvaluator`.
- `runtime/src/allocator/RuntimeExports.h`: the C entry points and their contracts.
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`: `getOrCreateWrapper`, `PapCreateOpLowering`, `PapExtendOpLowering` (`lowerGenericApply`, `lowerSegmentationUnknown` and the typed arms), `emitFastClosureCall`, `emitInlineClosureCall`, `emitClosureCall`, `getOrCreateEvalDesc`, `getOrCreateEvalDescForFunc` and `getOrCreateSatEntry`.
- `runtime/src/codegen/EcoBackend.cpp`: `expandSatMarkers` and `runCapInlinePrepass`.
- `runtime/src/allocator/NurserySpace.cpp`: closure tracing at `Tag_Closure`.
- `compiler/src/Compiler/Generate/MLIR/Functions.elm`: `generateClosureFuncWithClones` and `generateGenericCloneFunc`. `Lambdas.elm` does the same for nested lambdas.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`: `generateCall`, `generateGenericApply`, `generateUnknownSegmentationCall`, `generateFastDispatchCall`, `applyByStages` and `generateClosure`.
- `runtime/src/codegen/Ops.td`: `eco.papCreate`, `eco.papCreateGroup`, `eco.papExtend` and `eco.project.closure`.

Invariants (`design_docs/invariants.csv`):

- GOPT_003, GOPT_016: staging preserves meaning; unprovable calls stay generic.
- CGEN_052: a typed application's remaining arity is proven. CGEN_080: a stamp takes precedence over the call kind for closure values. CGEN_057: a kernel in closure position gets a back-end wrapper.
- CGEN_059, CGEN_060: no boxing allocations in the IR for generic calls.
- LSS_009, LSS_036: stamps only on provable single instances.
- RUNTIME_CLOSURE_004: over-application recurses through generic apply.
- REP_CLOSURE_001, FORBID_CLOSURE_001: only Int, Float and Char are raw in closures; Bool is boxed. REP_CLOSURE_002: arguments are converted to declared slot kinds.
- HEAP_033: interned zero-capture closures. HEAP_034: closures are traced to `n_values`. HEAP_078: the 2047-parameter layout and every reader of it. HEAP_SNAPSHOT_001: published objects are never written.

Rows that disagree with the code (trust the code):

- CGEN_CLOSURE_005, 007 and 008 describe a dispatch-mode attribute on every closure call. No pass sets it, and no lowering reads it.
- CGEN_058 names `eco_apply_closure` and CGEN_059 names `eco_apply_closure_typed` as the generic lowering. CGEN_060 names `eco_apply_segmentation_unknown` with bitmap-based extension. Both generic kinds call `eco_apply_closure_eval`, and partial calls use `eco_pap_extend_l` with a layout.
- RUNTIME_CLOSURE_004 places the over-application chain in `eco_apply_closure`. It is in `eco_apply_closure_eval`.
- HEAP_033's main text gives a different packed-word layout. Its amendment and the code use HEAP_078's 11/11/2/40 layout.

Comments that disagree with the code:

- `Ops.td`'s `papExtend` example: shows the dispatch-mode attribute that nothing sets.
- The comment above `expandSatMarkers`: "25 slots" where the guard uses 20.
- `Heap.hpp`'s `EvalParamLayout` comment: a capability bit on a closure flags field that does not exist.
- `RuntimeExports.h`: the doc for `eco_apply_closure_eval` sits above the segmentation-unknown declaration, and `eco_alloc_closure_k`'s evaluator parameter is documented as a function pointer though it is a descriptor.
- `generateGenericApply`'s doc comment in `Expr.elm`: says all arguments are boxed; only Bool is.
- The `CallOpLowering` comment calling `emitClosureCall` "NOT dead".
