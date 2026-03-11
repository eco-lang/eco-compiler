# Global Optimization Phase Performance Fix

## Problem

The Global Optimization phase takes >10 minutes on a 34K-node graph, making self-compilation infeasible. Profiling identifies three bottlenecks:

1. **`maxLambdaIndexInGraph`** (>7 min): Full AST traversal via `foldExpr` over all 34K nodes just to seed a counter
2. **`buildCallGraph` edge collection** (~50s): Another full `foldExpr` traversal of every node to extract call edges
3. **SCC computation** (~120s): `Set.member` (O(log N)) used for visited tracking in Kosaraju's algorithm

---

## Part 1: Thread `nextLambdaIndex` Through the Pipeline

### Current State

Three places need a lambda counter seed:

| Location | Current approach |
|---|---|
| `MonoGlobalOptimize.elm:50` `initGlobalCtx` | Scans entire graph via `maxLambdaIndexInGraph` |
| `Staging/Rewriter.elm:36` `initRewriteCtx` | Scans entire graph via `maxLambdaIndexInGraph` |
| `MonoInlineSimplify.elm:400` `initRewriteCtx` | Hardcoded `1000000` (fragile, disjoint range) |

The authoritative counter is `MonoState.lambdaCounter` (`Monomorphize/State.elm:46`), incremented monotonically during specialization (`Specialize.elm:225`).

Confirmed: `AbiCloning` and `annotateCallStaging` do **not** allocate lambda IDs (no `AnonymousLambda` or `freshLambdaId` usage).

### Changes

#### Step 1.1: Add `nextLambdaIndex` to `MonoGraph`

**File:** `compiler/src/Compiler/AST/Monomorphized.elm:349-355`

```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        , nextLambdaIndex : Int
        }
```

#### Step 1.2: Set it during monomorphization

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm:119-124`

```elm
Ok
    (Mono.MonoGraph
        { nodes = finalState.nodes
        , registry = finalState.registry
        , main = mainInfo
        , ctorShapes = ctorShapes
        , nextLambdaIndex = finalState.lambdaCounter
        }
    )
```

#### Step 1.3: Update all `MonoGraph` construction/destructuring sites

Every place that pattern-matches or constructs `MonoGraph` must include the new field. Known sites:

| File | Line(s) | Pattern |
|---|---|---|
| `Monomorphize.elm` | 119 | Construction |
| `MonoGlobalOptimize.elm` | 130, 1010, 1078 | Destructure / reconstruct with `{ record0 \| nodes = ... }` |
| `MonoInlineSimplify.elm` | 53, 88-89 | Full destructure + reconstruct |
| `Backend.elm` | 50 | Full destructure |
| `Staging/Rewriter.elm` | 35, 61, 64, 82 | Destructure / reconstruct |
| `Staging/GraphBuilder.elm` | 53 | Destructure |
| `Staging/ProducerInfo.elm` | 33 | Destructure |

For destructures that use `{ nodes }` or `{ nodes, main, ... }` patterns: just add the field if needed, or leave it in the record if using `record` alias.

For reconstructions using `{ record | nodes = newNodes }`: the field is preserved automatically.

For full reconstructions (like `MonoInlineSimplify.optimize`): must include `nextLambdaIndex`.

#### Step 1.4: Wire `MonoGlobalOptimize.initGlobalCtx` to use the field

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm:47-50`

```elm
initGlobalCtx (Mono.MonoGraph record) =
    { registry = record.registry
    , lambdaCounter = record.nextLambdaIndex
    }
```

Update `wrapTopLevelCallables` (`MonoGlobalOptimize.elm:989-1009`) to propagate the final counter back:

```elm
wrapTopLevelCallables (Mono.MonoGraph record0) =
    let
        ctx0 = initGlobalCtx (Mono.MonoGraph record0)
        ( newNodes, finalCtx ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) -> ...)
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes, nextLambdaIndex = finalCtx.lambdaCounter }
```

#### Step 1.5: Wire `Staging/Rewriter` to use the field

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm:34-37`

```elm
initRewriteCtx (Mono.MonoGraph record) =
    { lambdaCounter = record.nextLambdaIndex
    , home = IO.Canonical ( "eco", "internal" ) "GlobalOpt"
    }
```

Update `applyStagingSolution` (`Rewriter.elm:60-81`) to propagate the final counter:

```elm
applyStagingSolution solution producerInfo (Mono.MonoGraph mono0) =
    let
        ctx0 = initRewriteCtx (Mono.MonoGraph mono0)
        ( nodes1, finalCtx ) =
            Dict.foldl compare
                (\nodeId node ( accNodes, accCtx ) -> ...)
                ( Dict.empty, ctx0 )
                mono0.nodes
        mono1 = { mono0 | nodes = nodes1, nextLambdaIndex = finalCtx.lambdaCounter }
    in
    Mono.MonoGraph mono1
```

#### Step 1.6: Wire `MonoInlineSimplify` into the shared counter

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

Change `initRewriteCtx` (line 390) to accept `nextLambdaIndex` instead of hardcoding `1000000`:

```elm
initRewriteCtx nodes registry callGraph nextLambdaIndex =
    { nodes = nodes
    , registry = registry
    , callGraph = callGraph
    , whitelist = defaultWhitelist
    , inlineCountThisFunction = 0
    , varCounter = 0
    , lambdaCounter = nextLambdaIndex
    , metrics = { inlineCount = 0, betaReductions = 0, letEliminations = 0 }
    }
```

Change `optimize` (line 50) to:
- Read `nextLambdaIndex` from the graph
- Pass it to `initRewriteCtx`
- Return the updated `nextLambdaIndex` in the output graph

```elm
optimize graph =
    let
        (MonoGraph { nodes, main, registry, ctorShapes, nextLambdaIndex }) = graph
        ...
        ctx = initRewriteCtx nodes registry callGraph nextLambdaIndex
        ( optimizedNodes, finalCtx ) = ...
    in
    ( MonoGraph
        { nodes = optimizedNodes
        , main = main
        , registry = registry
        , ctorShapes = ctorShapes
        , nextLambdaIndex = finalCtx.lambdaCounter
        }
    , metrics
    )
```

#### Step 1.7: Delete dead code

Remove from `MonoGlobalOptimize.elm`:
- `maxLambdaIndexInGraph` (line 129)
- `maxLambdaIndexInNode` (line 137)
- `maxLambdaIndexInExpr` (line 182)

Remove from `Staging/Rewriter.elm`:
- `maxLambdaIndexInGraph` (line 709)
- `maxLambdaIndexInNode` (line 717)
- `maxLambdaIndexInExpr` (line 733)
- `maxLambdaIndexInDef` (line 796)

### Impact

Eliminates >7 minutes of AST traversal. All lambda counter seeds become O(1).

---

## Part 2: Collect Call Edges During Monomorphization

### Current State

`buildCallGraph` (`MonoInlineSimplify.elm:156-228`) iterates over all nodes, calling `collectCallsFromNode` → `collectCalls` → `Traverse.foldExpr extractSpecId []` on each. This walks every expression in every node (~50s for 34K nodes).

The information is already available during monomorphization: every `MonoVarGlobal` is emitted in `Specialize.elm` (lines 738, 770, 789, 808, 878, 1215, 1427, 1459).

### Changes

#### Step 2.1: Add `callEdges` to `MonoGraph`

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        , nextLambdaIndex : Int
        , callEdges : Dict Int Int (List Int)  -- SpecId -> [called SpecIds]
        }
```

#### Step 2.2: Collect edges after each node specialization

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm:178-271`

In `processWorklist`, after `Specialize.specializeNode` returns `(monoNode, stateAfter)`, collect call edges from the freshly created node and store them:

```elm
edges = collectCallsFromNode monoNode  -- O(size of this one node)
newState =
    { stateAfter
        | ...
        , callEdges = Dict.insert identity specId edges stateAfter.callEdges
    }
```

This requires:
- Adding `callEdges : Dict Int Int (List Int)` to `MonoState` (`State.elm:40-52`)
- Initializing it to `Dict.empty` in `initState`
- Inlining the simple call-collection logic directly in `processWorklist` (walk the node's expressions for `MonoVarGlobal` references)
- Including `callEdges` in the `MonoGraph` construction in `monomorphizeFromEntry`

For the accessor/extern/ctor cases in `processWorklist`, the call edges are empty (`[]`).

#### Step 2.3: Use precomputed edges in `buildCallGraph`

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm:156-228`

Replace the edge-collection loop with a direct read from the graph:

```elm
buildCallGraph (MonoGraph { nodes, callEdges, ... }) _ =
    let
        -- Use precomputed edges directly
        edges = callEdges

        -- Build SCC from edges...
        graphNodes = ...
        sccs = Graph.stronglyConnComp graphNodes
        ...
    in
    { edges = edges, isRecursive = isRecursive }
```

**Important caveat:** `MonoInlineSimplify.optimize` may introduce new call edges via inlining. After the inline/simplify pass, the `callEdges` in the graph are stale. This is acceptable because:
- The call graph is only used *within* `optimize` to guide inlining decisions
- Subsequent phases (`wrapTopLevelCallables`, staging) don't use `callEdges`
- If a future phase needs fresh edges, it can re-collect them from its own output

#### Step 2.4: Delete redundant traversal code

Remove from `MonoInlineSimplify.elm`:
- The edge-collection loop inside `buildCallGraph` (the `Dict.foldl` that calls `collectCallsFromNode`)
- `collectCallsFromNode` (line 232)
- `collectCalls` (line 275)
- `extractSpecId` (line 265)

### Impact

Eliminates ~50s of `foldExpr` traversal during `buildCallGraph`. Edge collection is amortized across monomorphization (O(node size) per node, same total work but done incrementally with less GC pressure).

---

## Part 3: BitSet Module + Faster SCC

### Current State

`Graph.elm` uses `Set Int` for visited tracking in `reversePostOrder`, `rpoHelp`, `kosaraju`, `collectComponent`, and `collectHelp`. Also uses `Set Int` for `selfLoops` in `buildGraphs`. For 34K nodes, the O(log N) tree operations and allocation pressure accumulate to ~120s.

### Changes

#### Step 3.1: Create `Compiler.Data.BitSet` module

**File:** `compiler/src/Compiler/Data/BitSet.elm`

Implement a compact bitset using `Array Int`, where each `Int` stores 32 bits packed via `Bitwise` operations.

**Why `Array Int` over alternatives:**
- `Array Bool`: Each `Bool` is a separate heap object (tag + pointer). 100K flags = 100K heap objects, heavy GC pressure.
- `Set Int`: Balanced tree with pointer-chasing, `_Utils_cmp`, per-element allocations. O(log N) with large constant factor.
- `Array Int` (packed): ~32x fewer array elements than `Array Bool`, no per-bit heap nodes. For 34K nodes the array is ~1069 elements; for 100K it's ~3125. Tree depth is tiny (RRB branching factor ~32), so `get`/`set` are effectively O(1).

**Representation:**

```elm
module Compiler.Data.BitSet exposing
    ( BitSet
    , empty
    , fromSize
    , fromWords
    , member
    , insert
    , remove
    , setWord
    , orWord
    )

import Array exposing (Array)
import Bitwise


type alias BitSet =
    { size : Int        -- number of bits (universe size 0..size-1)
    , words : Array Int -- each Int holds 32 bits
    }


wordSize : Int
wordSize =
    32
```

**Construction:**

```elm
empty : BitSet
empty =
    { size = 0, words = Array.empty }


fromSize : Int -> BitSet
fromSize nBits =
    { size = nBits
    , words = Array.repeat ((nBits + wordSize - 1) // wordSize) 0
    }
```

For SCC over `n` vertices: `fromSize n` once, then thread through.

**Indexing helpers:**

```elm
wordIndex : Int -> Int
wordIndex bitIndex =
    bitIndex // wordSize


bitOffset : Int -> Int
bitOffset bitIndex =
    bitIndex |> modBy wordSize
```

**Query — `member`:**

```elm
member : Int -> BitSet -> Bool
member bitIndex set =
    if bitIndex < 0 || bitIndex >= set.size then
        False

    else
        case Array.get (wordIndex bitIndex) set.words of
            Nothing ->
                False

            Just word ->
                Bitwise.and (Bitwise.shiftRightZfBy (bitOffset bitIndex) word) 1 /= 0
```

Uses `shiftRightZfBy` (JS `>>>`) to shift the target bit into position 0, then mask with 1.

**Mutation — `insert` / `remove`:**

```elm
insert : Int -> BitSet -> BitSet
insert bitIndex set =
    if bitIndex < 0 || bitIndex >= set.size then
        set

    else
        let
            wIndex = wordIndex bitIndex
            mask = Bitwise.shiftLeftBy (bitOffset bitIndex) 1
        in
        case Array.get wIndex set.words of
            Nothing ->
                set

            Just word ->
                { set | words = Array.set wIndex (Bitwise.or word mask) set.words }


remove : Int -> BitSet -> BitSet
remove bitIndex set =
    if bitIndex < 0 || bitIndex >= set.size then
        set

    else
        let
            wIndex = wordIndex bitIndex
            mask = Bitwise.shiftLeftBy (bitOffset bitIndex) 1
        in
        case Array.get wIndex set.words of
            Nothing ->
                set

            Just word ->
                { set | words = Array.set wIndex (Bitwise.and word (Bitwise.complement mask)) set.words }
```

Each `insert`/`remove` is one `Array.get` + one `Array.set` (both O(log32 N), effectively O(1)) plus a handful of integer bitwise ops. GC pressure is minimal: only the path nodes in the RRB tree are reallocated.

**Word-level bulk operations — `setWord` / `orWord` / `fromWords`:**

For algorithms that can batch updates by word (e.g., dense initialization, bulk union), word-level operations reduce from up to 32 `Array.set` calls per 32 bits down to 1:

```elm
-- Overwrite word at index wIndex
setWord : Int -> Int -> BitSet -> BitSet
setWord wIndex newWord set =
    if wIndex < 0 || wIndex >= Array.length set.words then
        set
    else
        { set | words = Array.set wIndex newWord set.words }


-- Merge bits into existing word via OR
orWord : Int -> Int -> BitSet -> BitSet
orWord wIndex wordMask set =
    if wIndex < 0 || wIndex >= Array.length set.words then
        set
    else
        case Array.get wIndex set.words of
            Nothing ->
                set

            Just oldWord ->
                { set | words = Array.set wIndex (Bitwise.or oldWord wordMask) set.words }


-- Construct from pre-built word array (zero Array.set calls)
fromWords : Int -> Array Int -> BitSet
fromWords size words =
    { size = size, words = words }
```

`setWord`/`orWord` enable a pattern where algorithms accumulate bits into a local `Int` variable (cheap, no allocation) and flush once per 32 indices:

```elm
-- Example: build a bitset by scanning linearly, flushing one word at a time
buildFromPredicate : Int -> (Int -> Bool) -> BitSet
buildFromPredicate nBits shouldSet =
    let
        nWords = (nBits + wordSize - 1) // wordSize
        words =
            Array.initialize nWords
                (\wIndex ->
                    let
                        base = wIndex * wordSize
                        bitsInWord = min wordSize (nBits - base)
                    in
                    List.foldl
                        (\offset acc ->
                            if shouldSet (base + offset) then
                                Bitwise.or acc (Bitwise.shiftLeftBy offset 1)
                            else
                                acc
                        )
                        0
                        (List.range 0 (bitsInWord - 1))
                )
    in
    fromWords nBits words
```

**When word-level batching helps vs. doesn't:**
- Helps: Dense initialization, bulk union/intersection, linear scans where bits are set in word order
- Doesn't help much: Sparse random-order access (e.g., DFS visiting vertices irregularly) — but even there, the packed representation is still much better than `Set Int`

For SCC's `visited` set, the main win comes from the packed representation itself (bit-level `insert`/`member`). Word-level batching would help if we ever need bulk initialization (e.g., "mark all vertices in a range as visited").

**Note on Elm's `Int`:** Elm integers are JS doubles, but `Bitwise` operations coerce to 32-bit signed integers. This gives 32 usable bits per word. `Bitwise.shiftRightZfBy` compiles to JS `>>>` (unsigned right shift).

#### Step 3.2: Write tests for `BitSet`

**File:** `compiler/tests/Compiler/Data/BitSetTest.elm`

Test cases:

**Bit-level operations:**
- `empty` has size 0, no members
- `fromSize n` has no members initially
- `insert` then `member` returns True
- `member` on unset bit returns False
- Multiple inserts in same word (e.g., bits 0, 5, 15, 31)
- Inserts across word boundaries (bits 31, 32, 33)
- `remove` clears a set bit
- `remove` on unset bit is no-op
- Large indices (e.g., 34000)
- Boundary: index 0, index 31, index 32
- `member` on negative index returns False
- `member` on index >= size returns False
- `insert` on out-of-range index is no-op (returns unchanged set)
- `remove` on out-of-range index is no-op

**Word-level operations:**
- `setWord` overwrites a word, bits in that word reflect the new value
- `setWord` with out-of-range word index is no-op
- `orWord` merges bits (existing bits preserved, new bits added)
- `orWord` with out-of-range word index is no-op
- `fromWords` constructs bitset with correct membership
- Word-level and bit-level operations interoperate correctly (set word, then member individual bits)

Register test in `elm-test-rs` suite (check `elm.json` test-dependencies and test runner config).

#### Step 3.3: Replace `Set Int` with `BitSet` in `Graph.elm`

**File:** `compiler/src/Compiler/Graph.elm`

The SCC nodes are already mapped to dense integer IDs `0..n-1` (via `keyToId`/`binarySearch` in `stronglyConnCompR`), so they're perfect for a bitset.

All functions use dense integer IDs `0..n-1`, which is the ideal use case for a bitset.

**`reversePostOrder`** (line 240):
```elm
-- Before: ( Set.empty, [] )
-- After:  ( BitSet.fromSize n, [] )
```

**`rpoHelp`** (line 261):
```elm
-- Before: if Set.member v visited
-- After:  if BitSet.member v visited

-- Before: Set.insert v visited
-- After:  BitSet.insert v visited
```

**`kosaraju`** (line 183):
```elm
-- Before: ( Set.empty, [] )
-- After:  ( BitSet.fromSize n, [] )

-- Before: if Set.member v visited
-- After:  if BitSet.member v visited
```

**`collectComponent`/`collectHelp`** (lines 289-308): Same pattern.

**`buildGraphs`** — `selfLoops : Set Int` → `selfLoops : BitSet` with word-level batching:

`buildGraphs` iterates with `idx` from 0 to n-1 monotonically via `Array.foldl`. This is the ideal case for word-level batching: accumulate self-loop bits into a local `Int` word, and flush with `BitSet.setWord` every 32 indices.

Current code (`Graph.elm:122-169`):
```elm
-- In the accumulator:
{ idx = 0, fwd = emptyAdj, trans = emptyAdj, loops = Set.empty }

-- Per iteration:
newLoops =
    if hasSelfLoop then
        Set.insert acc.idx acc.loops
    else
        acc.loops
```

New approach — add `loopWord : Int` and `loopWordIndex : Int` to the accumulator:
```elm
-- Initial accumulator:
{ idx = 0
, fwd = emptyAdj
, trans = emptyAdj
, loops = BitSet.fromSize n
, loopWord = 0        -- current 32-bit word being built
}

-- Per iteration, accumulate the bit locally:
bitOffset = modBy 32 acc.idx
wordWithBit =
    if hasSelfLoop then
        Bitwise.or acc.loopWord (Bitwise.shiftLeftBy bitOffset 1)
    else
        acc.loopWord

-- Flush when crossing a word boundary (bitOffset == 31) or on the last element:
( newLoops, newLoopWord ) =
    if bitOffset == 31 || acc.idx == n - 1 then
        ( BitSet.setWord (acc.idx // 32) wordWithBit acc.loops
        , 0
        )
    else
        ( acc.loops, wordWithBit )
```

This reduces self-loop tracking from up to N `Set.insert` calls (each O(log N) with tree allocations) to N/32 `BitSet.setWord` calls (each a single `Array.set`). For 34K nodes: ~1069 array updates instead of up to 34K set insertions.

The `kosaraju` function checks `Set.member single selfLoops` — change to `BitSet.member`.

#### Step 3.4: Update type signatures

`buildGraphs` return type changes from `( Array (List Int), Array (List Int), Set Int )` to `( Array (List Int), Array (List Int), BitSet )`.

`kosaraju` parameter type changes accordingly.

`reversePostOrder`, `rpoHelp`, `collectComponent`, `collectHelp` — internal types change but no public API change.

The public API (`stronglyConnComp`, `stronglyConnCompR`, `SCC` type) remains unchanged.

Remove the `import Set` from `Graph.elm` (no longer needed after this change).

### Impact

Reduces SCC from ~120s to likely <10s. Each `member`/`insert` is O(log32 N) via `Array.get`/`Array.set` (effectively O(1) for N < 100K), with minimal allocation pressure (array COW of ~1K elements vs. tree rebalancing of 34K-node `Set`).

---

## Execution Order

1. **Part 3** (BitSet + SCC) — self-contained, no cross-cutting changes, can be tested independently
2. **Part 1** (thread `nextLambdaIndex`) — highest impact, cross-cutting but mechanical
3. **Part 2** (call edges in monomorphization) — depends on Part 1's `MonoGraph` field additions

## Verification

After each part:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1   # Frontend tests
cmake --build build --target check                             # Full E2E tests
```

## Resolved Decisions

- **`BitSet.elm` location:** `compiler/src/Compiler/Data/BitSet.elm`
- **`BitSet` tests:** `compiler/tests/Compiler/Data/BitSetTest.elm`
- **`collectCallsFromNode` placement:** Inline the simple logic directly in `processWorklist` — no shared utility needed
- **`callEdges` key type:** `Dict Int Int (List Int)` with `identity` comparator, consistent with existing `SpecId` usage
- **`AbiCloning` / `annotateCallStaging`:** Confirmed they do NOT allocate lambda IDs — no counter threading needed
