# Plan: Single-Pass Mark & Filter Pruning with BitSet over callEdges

## Status: BLOCKED — upstream bug in `callEdges` (see analysis below)

## Goal
Replace the BFS-over-expressions reachability in `Compiler.Monomorphize.Prune` with a BitSet-based DFS traversal over the precomputed `callEdges` adjacency.

## Root Cause Analysis: Why callEdges-based pruning fails

### Failure Category
All 702 elm-test failures fall into two categories, both caused by the same root issue:

1. **MONO_011 violations** (referenced specId not in nodes): e.g., `"Referenced SpecId 2 is not defined in nodes"`
2. **CGEN_044 violations** (eco.call references undefined function): e.g., `"eco.call references undefined function 'unknown_$_2'"`

Both are downstream consequences of over-eager pruning removing specIds that are still referenced by live nodes' expressions.

### Evidence: callEdges is incomplete

Debug instrumentation comparing the old (expression-traversal, EverySet) live set against the new (callEdges, BitSet) live set reveals a clear mismatch. For the "Simple addition" test case:

```
PRUNE MISMATCH!
In old (EverySet) but NOT in new (BitSet): [2,4,5,6]

Per-specId info:
  sid=0 hasNode=True callEdges=[1]    exprRefs=[2,1]
  sid=1 hasNode=True callEdges=[3]    exprRefs=[3]
  sid=2 hasNode=True callEdges=[]     exprRefs=[]
  sid=3 hasNode=True callEdges=[]     exprRefs=[5,6,4]
  sid=4 hasNode=True callEdges=[]     exprRefs=[]
  sid=5 hasNode=True callEdges=[]     exprRefs=[]
  sid=6 hasNode=True callEdges=[]     exprRefs=[]
```

Key observations:
- **specId 0** (main): `callEdges=[1]` but `exprRefs=[2,1]` — callEdges **missing specId 2**
- **specId 3**: `callEdges=[]` but `exprRefs=[5,6,4]` — callEdges **missing specIds 4, 5, 6**
- DFS from main over callEdges reaches: {0, 1, 3} (3 nodes)
- BFS from main over expressions reaches: {0, 1, 2, 3, 4, 5, 6} (all 7 nodes)

### Root Cause: Bug in `MonoTraverse.foldExpr`

The `callEdges` are built in `Monomorphize.elm` via:

```elm
callEdges = Dict.insert identity specId (collectCallsFromNode monoNode) stateAfter.callEdges
```

where `collectCallsFromNode` uses:

```elm
collectCalls : Mono.MonoExpr -> List Int
collectCalls = Traverse.foldExpr extractSpecId []
```

**The bug is in `Compiler.GlobalOpt.MonoTraverse.foldExprAccFirst`** (line 213):

```elm
foldExprAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprAccFirst f acc expr =
    let
        childAcc =
            foldExprChildren f acc expr   -- <-- passes `f`, not `foldExprAccFirst f`
    in
    f childAcc expr
```

Compare with the correctly recursive `traverseExpr` (line 102):

```elm
traverseExpr : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> MonoExpr -> ( MonoExpr, ctx )
traverseExpr f ctx expr =
    let
        ( mapped, ctx1 ) =
            traverseExprChildren (traverseExpr f) ctx expr   -- <-- passes `traverseExpr f` (recursive!)
    in
    f ctx1 mapped
```

And the correctly recursive `mapExpr` (line 44):

```elm
mapExpr : (MonoExpr -> MonoExpr) -> MonoExpr -> MonoExpr
mapExpr f expr =
    f (mapExprChildren (mapExpr f) expr)   -- <-- passes `mapExpr f` (recursive!)
```

`foldExprChildren` (line 574) is designed to process **one level of children only**, delegating recursion to its caller by invoking the function it receives on each child. For `mapExpr` and `traverseExpr`, this function is the recursive wrapper (`mapExpr f`, `traverseExpr f`). But for `foldExprAccFirst`, it's the raw user function `f`, which does NOT recurse.

As a result, `foldExpr` only processes the **top-level expression and its immediate children** — it does not recurse into nested subexpressions. Any `MonoVarGlobal` deeper than one level is missed.

### The fix needed (not in Prune.elm)

`foldExprAccFirst` should be:

```elm
foldExprAccFirst f acc expr =
    let
        childAcc =
            foldExprChildren (foldExprAccFirst f) acc expr   -- <-- recursive!
    in
    f childAcc expr
```

This matches the pattern used by `mapExpr` and `traverseExpr`.

### Why the old Prune code works despite this bug

The old `Prune.elm` uses its own manually-written `collectRefsFromExpr` which correctly recurses through all expression constructors. It does NOT use `MonoTraverse.foldExpr`. So pruning correctly identifies all reachable specIds.

The `callEdges` built during monomorphization are incomplete (due to the `foldExpr` bug), but the old pruning code ignores `callEdges` entirely and re-traverses expressions. This masks the bug — `callEdges` is wrong but nobody noticed because no one relied on it for correctness until this plan tried to.

### Impact of the foldExpr bug beyond pruning

`MonoTraverse.foldExpr` is currently only used in one place:
- `Monomorphize.elm:collectCalls` → builds `callEdges`

Since nothing else currently relies on `callEdges` for correctness (only `MonoInlineSimplify` reads it, for call graph construction), the bug has been latent. However, the `foldExpr` function is a public API that could be used by future code, so it should be fixed regardless.

### Recommended action

1. **Fix `MonoTraverse.foldExprAccFirst`** to pass `foldExprAccFirst f` instead of `f` to `foldExprChildren`
2. **Verify `callEdges` are now correct** by re-running the debug comparison
3. **Then proceed with the original plan** to switch Prune.elm to use callEdges + BitSet

## Original Plan (deferred until foldExpr is fixed)

### File: `compiler/src/Compiler/Monomorphize/Prune.elm`

1. **Update imports**: Replace `Data.Set` with `Compiler.Data.BitSet`
2. **Delete old helpers**: Remove `collectRefsFromExpr`, `collectRefsFromDef`, `collectRefsFromDecider`, `collectRefsFromNode`, `reachableStep`
3. **Add `markReachable`**: DFS over `callEdges` using explicit stack, returns `BitSet`
4. **Rewrite `reachableFromMain`**: Return `BitSet`, use `markReachable` over `record.callEdges`
5. **Update `pruneUnreachableSpecs`**: Change `live` type to `BitSet`, replace `Set.member` with `BitSet.member`

### Verification
- `npx elm-test-rs --project build-xhr --fuzz 1` (frontend tests)
- `cmake --build build --target check` (E2E tests)
