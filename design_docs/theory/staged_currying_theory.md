# Staged Currying Theory

## Overview

Staged currying is a technique for determining how functions should segment their arguments when generating efficient native code. Rather than naively currying all functions (creating closures for each argument), or requiring all arguments at once (losing Elm's currying semantics), staged currying finds an optimal balance.

**Phase**: Global Optimization (GlobalOpt)

**Pipeline Position**: After Monomorphization, before MLIR Generation

**Related Invariants**: **GOPT_001** — a closure's type has as many parameters in its first stage as the closure takes; **GOPT_003** — a function-valued MonoCase/MonoIf makes no staging claim beyond what all its branches agree on (rewritten Oct 2026).

**Note**: This logic was moved from Monomorphization to GlobalOpt to achieve a clean separation of concerns: Monomorphization is staging-agnostic and focuses on specialization, while GlobalOpt handles all calling-convention and ABI decisions.

## Motivation

Elm functions are semantically curried: `add : Int -> Int -> Int` can be partially applied as `add 1` to get an `Int -> Int` function. However, native code generation benefits from knowing when multiple arguments will always be applied together.

Consider:
```elm
map2 : (a -> b -> c) -> List a -> List b -> List c
map2 f xs ys = ...
```

In practice, `map2` is almost always called with all three arguments. Generating a fully curried version (closure for each argument) wastes allocation and introduces indirection. Staged currying detects this pattern and generates a version that takes all three arguments at once.

## Core Concepts

### Staging Signature

A staging signature describes how a function's arguments are grouped:

```elm
-- Staging [3] means: take 3 args at once, return result
-- Staging [2,1] means: take 2 args, return closure taking 1 arg
-- Staging [1,1,1] means: fully curried
```

For `\a b -> \c -> body`:
- The programmer wrote two lambdas: one taking `a,b` and one taking `c`
- Natural staging is `[2,1]`: take 2 args, return closure that takes 1 arg

### Staged Function Representation

```elm
type MonoStagedFunction
    = MonoStagedFunction
        { params : List (Name, MonoType)      -- All parameters
        , staging : List Int                   -- Argument grouping
        , captures : List (Name, MonoType)    -- Captured variables
        , body : MonoExpr
        , resultType : MonoType
        }
```

### Compatibility

Two staging signatures are compatible if they have the same total arity and grouping:

```
[3] compatible with [3]           -- same
[2,1] compatible with [2,1]       -- same
[3] NOT compatible with [2,1]     -- different grouping
```

## Joins of Differently Staged Functions

When a case or if expression returns functions from different branches, the branches may be staged differently.

### The Problem

```elm
chooser : Bool -> (Int -> Int -> Int)
chooser b =
    if b then
        \x y -> x + y          -- natural staging: [2]
    else
        \x -> \y -> x * y      -- natural staging: [1,1]
```

A caller of `chooser b` cannot know statically which of the two closures it receives.

### What the Compiler Does

**Branches keep their own staging.** GlobalOpt regroups each closure's type to its own parameter count (`Staging.regroup`, GOPT_001) and never re-stages one branch to agree with another. Instead it makes no claim about the join that the branches do not all share:

- `MonoGlobalOptimize.closureBodyStageArities` returns `Just stages` only when every branch (case jump targets **and** decision-tree `Inline` leaves, through `Chain`/`FanOut`; every if branch **and** the else) is a closure with the same stage arities. Otherwise it returns `Nothing`.
- A call whose callee value can come from such a join therefore gets no derived `initialRemaining`/`remainingStageArities`; it is `CallSegmentationUnknown` or `CallGenericApply`.
- Codegen applies such a value generically: the runtime reads the selected closure's header (its arity and remaining count) and applies the arguments stage by stage. Every staging produces the same value, so this is always correct; it is only slower than a known-segmentation call.

**Why balancing the branches was unnecessary.**
1. Codegen already applies runtime-selected function values generically, so a join never needs one uniform staging to be called correctly.
2. Pre-mono η-expansion to declared arity rewrites a join that is a definition's whole body. `chooser` above becomes a three-argument function whose branches compute `x + y` / `x * y` directly, so the join disappears before monomorphization.
3. The joins η cannot dissolve (let-bound, stored in a list, passed as an argument, held in a record field) are exactly where a call site cannot see the join anyway; they are applied generically.

### History: majority staging (removed Oct 2026)

Earlier designs balanced the branches: collect each branch's natural staging, pick the most common (ties to the larger first group), and eta-wrap the others (`\x -> \y -> x * y` became `\x y -> (\x -> \y -> x * y) x y`). It was implemented twice: as a case/if normalizer in `MonoGlobalOptimize` (`rewriteExprForAbi`, `computeBranchNormalization`, `buildAbiWrapperGO`, ...), which nothing called, and as the class vote of the staging solver (see "Callsite Derivation" below), which measured zero wrappers on every corpus because it never saw a case's inline branches. Both were deleted (plans/staging-honesty-and-production-test-pipeline.md P2/P3).

## Invariant GOPT_003

**Statement**: After GlobalOpt a function-valued MonoCase or MonoIf makes no staging claim beyond what all of its branches agree on. Its stored type may differ from a branch's staging, and branch values are never re-staged to agree. No `CallInfo` derives `initialRemaining` or `remainingStageArities` from a join whose branches disagree.

**Rationale**: A claimed staging that is true of only one branch would make codegen emit a known-segmentation call for a value that may be staged differently at run time. Claiming nothing is always sound: the runtime applies the value by its closure header.

**Enforcement**: `MonoGlobalOptimize.closureBodyStageArities` (all branches must agree, see above).

**Checks**: `TestLogic.Monomorphize.MonoCaseBranchResultType.expectHonestJoinStaging` (on the production pipeline); E2E guard `test/elm/src/Gopt003CaseStagingTest.elm`; elm-test fixtures in `JoinpointABICases` category 6 (joins η-expansion cannot dissolve: let-bound, in a list, as an argument, in a record field).

## Kernel Function Special Case

Kernel functions (runtime primitives implemented in C++) cannot be stage-curried. They have fixed ABIs that expect all arguments at once.

```elm
-- Kernel function: List.map
-- ABI: (fn: eco.value, list: eco.value) -> eco.value
-- Cannot be split into stages
```

When a kernel function is partially applied in Elm code:
1. A PAP (partial application) wrapper is generated
2. The wrapper accumulates arguments until all are available
3. Only then is the kernel function called

```elm
-- Elm code:
mappedList = List.map f

-- Generated wrapper:
-- pap_List_map_1 : eco.value -> eco.value -> eco.value
-- pap_List_map_1 arg0 arg1 = List_map(arg0, arg1)
```

## Callsite Derivation

Every call site needs to know how its callee is staged. This is derived in GlobalOpt Phase 5 (`annotateCallStaging`), per function, from what the call site can see.

### The Problem

Consider a function that flows through intermediate bindings:

```elm
adder = \x y -> x + y              -- natural staging [2]
alias = adder                       -- what staging?
result = alias 1 2                  -- how to call?
```

The call site `alias 1 2` needs to know that `alias` has staging `[2]`.

### How It Is Derived

- **Globals**: the callee node is looked up in the graph; a closure or tail function supplies its parameter count (`sourceArityForExpr`) and its body's remaining stages (`closureBodyStageArities`). A global defined as an alias of another function is wrapped in an alias closure by Phase 1 (`wrapTopLevelCallables`), so it has a parameter list too.
- **Locals**: `CallEnv` records the source arity (`varSourceArity`) and body stage arities (`varBodyStageArities`) of let-bound and captured variables whose bound expression is known.
- **Unknown**: when nothing is known (`sourceArityForCallee` falls back to the type, `FromType`), or the callee is a function-typed parameter of the enclosing tail function (`CallEnv.dynamicParams`, `isDynamicCallee`), or it may come from a join whose branches disagree (GOPT_003), the call is `CallSegmentationUnknown` or `CallGenericApply` and the runtime applies the closure by its header.

### Kernel Function Integration

Kernel functions have fixed ABIs (all args at once). A direct kernel call is `FlattenedExternal`; a kernel used as a value at top level is wrapped in an alias closure by Phase 1, whose parameter count is the kernel's arity.

### History: the graph-based staging solver (removed Oct 2026)

Until October 2026 staging was decided by a program-wide solver (`Compiler.GlobalOpt.Staging.GraphBuilder`, `ProducerInfo`, `UnionFind`, `Solver`, `Types`, `Rewriter`). Closures, tail functions and kernels were *producers* with a natural segmentation; variable bindings, parameters, captures, if/case results and record/tuple/list slots were *slots*. Flows created edges, joins unioned slots, each equivalence class got a canonical segmentation by majority vote (kernels fixed), and disagreeing producers were eta-wrapped.

Measured on 2026-10-06 it inserted **zero** wrappers: self-compile 38,624 classes with none disagreeing, E2E corpus 936 programs / 8,412 classes, 1,124 elm-test programs. The builder never looked into a case's decision-tree `Inline` leaves (where nearly all branches live), never connected function arguments to parameters, and never traced let-bound variables (`varBindings` was never written); pre-mono η-expansion to declared arity dissolves the joins a vote could have reconciled. Its only effects were the type regrouping (now `Staging.regroup`) and `dynamicSlots`, which was exactly the function-typed parameters of `MonoTailFunc` nodes (now `CallEnv.dynamicParams`). Output is byte-identical without it.

## PAP Wrapper Elimination

**PAP Wrapper Elimination** is an optimization that enables direct function calls even when partial application and closures are involved, eliminating the overhead of PAP (partial application) wrapper functions.

### The Problem

Previously, when calling a function that might be a partial application:

```elm
applyTwice f x = f (f x)
```

The generated code had to:
1. Check if `f` is a PAP at runtime
2. If so, call through a generic `papExtend` mechanism
3. This added indirection and prevented optimization

### The Solution: Typed Closure Calling

The compiler now generates **direct calls** by leveraging type information:

1. **Homogeneous Call Path**: When all callsites can be statically determined to have the same closure structure (same captures, same parameter types), generate a direct call with captures unpacked as arguments.

2. **Heterogeneous Call Path**: When the closure structure varies across callsites (e.g., different branches return closures with different captures), generate a call that passes the entire closure pointer.

### ABI Splitting

For heterogeneous cases, the compiler generates two entry points:

```
-- Direct entry (homogeneous): captures unpacked
func_direct(capture1, capture2, arg1, arg2) -> result

-- Indirect entry (heterogeneous): closure passed
func_indirect(closure_ptr, arg1, arg2) -> result
```

The callsite derivation determines which entry point to use based on whether the callee's structure is statically known.

### Benefits

- **No runtime PAP checks**: The calling convention is determined at compile time
- **Direct calls**: Most calls are direct function calls, not indirect through PAP machinery
- **Better optimization**: LLVM can inline and optimize direct calls

### GC Safepoint Placement *(Apr 2026)*

GC safepoint emission was moved off the top of `CallOp` / `PapExtendOp` / `PapCreateOp`. These ops now supply GC roots; the safepoint marker is emitted immediately before each final GC-triggering call inside the closure dispatch helpers. No changes to currying shape or segmentation semantics.

## Implementation Details

### Staging Detection

During GlobalOpt, when processing a function:

```
FUNCTION detectStaging(monoExpr):
    CASE monoExpr OF
        MonoClosure closureInfo body _:
            innerStaging = detectStaging(body)
            RETURN [length(closureInfo.params)] ++ innerStaging

        _:
            RETURN []  -- Not a function, no more stages
```

### Integration with GlobalOpt

The GlobalOpt pass runs several phases:

0. *(External)*: `MonoInlineSimplify` - Inline small functions (applied before GlobalOpt)
1. **Phase 1**: `wrapTopLevelCallables` - Wrap bare kernel/global references in closures
2. **Phase 2**: `Staging.regroup` - Regroup each closure/tail-func type to its param count (GOPT_001); creates no values
3. *(Phase 3, the no-op `validateClosureStaging`, was removed; GOPT_001 is checked under `mono.validate` by `Compiler.Pipeline.Steps.checkClosureStaging`)*
4. **Phase 4**: `AbiCloning.abiCloningPass` - Clone functions for homogeneous closure ABIs; LSS singleton stamps (then `Mono.clearLssTables`)
5. **Phase 5**: `annotateCallStaging` - Annotate `CallInfo` metadata for MLIR codegen
6. **Phase 6**: `Borrow.run` - Borrow inference (when enabled)

After GlobalOpt, `Compiler.Pipeline.Steps` runs CSE, CAF dedupe and CAF hoisting, each behind its flag.

Staging is the single module `compiler/src/Compiler/GlobalOpt/Staging.elm`:

| Function | Purpose |
|--------|---------|
| `regroup` | Rewrite every `MonoClosure`/`MonoTailFunc` type with `flattenTypeToArity (params)`: first stage = the params, remaining arguments one further stage, head lambda-set annotation copied onto every stage; every `MonoDefine` takes its rewritten expression's type |
| `checkClosureStaging` | List GOPT_001 violations (run by `Steps.checkClosureStaging` under `mono.validate`) |

**LSS interaction**: regrouping copies a closure type's head lambda-set annotation onto every stage arrow (the rebuilder rule; partial applications keep the callee's member, design OQ4). Since staging creates no values, it creates no instances that would block AbiCloning's singleton stamps (LSS_008/LSS_009).

## Example: Complex Case

```elm
process : Int -> (Int -> Int -> Int)
process n =
    case n of
        0 -> \x y -> x
        1 -> \x -> \y -> y
        2 -> \x y -> x + y
        _ -> \x -> \y -> x - y
```

Stagings: `[2]`, `[1,1]`, `[2]`, `[1,1]`. Each branch keeps its own staging; `closureBodyStageArities` sees the branches disagree and returns `Nothing`, so a call through `process n` is applied generically (GOPT_003). In a production build pre-mono η-expansion first makes `process` a three-argument function, and the join disappears. (Under the removed majority vote, branches 1 and 3 would have been eta-wrapped to `[2]`.)

## Relationship to Other Passes

- **Requires**: Monomorphized expressions (MonoGraph from Monomorphization pass)
- **Enables**: Consistent function ABIs for MLIR code generation
- **Key Insight**: Function staging is a code generation concern, not a semantic one; all stagings produce the same values, just with different performance characteristics

### Why GlobalOpt, Not Monomorphization?

The staging logic was moved from Monomorphization to GlobalOpt to achieve a clean separation of concerns:

**Monomorphization responsibilities** (staging-agnostic):
- Specialize polymorphic functions
- Compute concrete layouts for records, tuples, custom types
- Preserve curried type structure from Elm semantics
- No closure wrappers created due to staging

**GlobalOpt responsibilities** (staging-aware):
- Canonicalize closure types to match param counts
- Make no staging claim for a case/if join beyond what all its branches agree on (GOPT_003)
- Compute call staging metadata (`CallInfo`) for MLIR
- All calling-convention decisions resolved

**MLIR codegen responsibilities** (staging-consuming):
- Switch on `CallInfo.callModel` (FlattenedExternal vs StageCurried)
- Use pre-computed `CallInfo` fields for partial application
- No independent staging computations

This separation ensures that Monomorphization remains focused on specialization semantics, while all ABI/calling-convention complexity is isolated in GlobalOpt.

**See also**: [Global Optimization Theory](pass_global_optimization_theory.md)
