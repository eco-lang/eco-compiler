# Convert Dict Int to Array for Contiguous-Key Dictionaries

## Motivation

The compiler contains several categories of `Dict Int v` where keys are contiguous integers
allocated from 0 by sequential counters. Elm's `Dict` is a balanced BST with O(log n)
lookup and significant per-entry overhead (two tree pointers + key storage). `Array` gives
O(~log32 n) lookup (effectively constant for realistic sizes) with zero per-entry overhead
beyond the value itself.

The existing `nodesToArray` function in `Monomorphized.elm` already converts the SpecId
Dict into an Array for the MLIR backend — proving the pattern is viable. This plan
generalizes that conversion upstream so the Array representation is used throughout.

### Existing infrastructure

- `Array` (Elm core): `get`, `set`, `push`, `foldl`, `indexedMap`, `fromList`, `repeat`, `length`
- `nodesToArray` in `Monomorphized.elm:751` already converts `Dict Int MonoNode → Array (Maybe MonoNode)`
- `Registry.reverseMapping` already uses `Array (Maybe (...))` keyed by SpecId
- `BitSet` already provides set-of-int semantics separate from Dict

### Prerequisite

Some files still use `Data.Map.Dict Int Int v` (the triple-type wrapper) rather than core
`Dict Int v` for their integer-keyed dicts. These are converted **directly to Array** in
this plan, skipping the intermediate core `Dict Int v` step.

---

## Representation Choice

For most categories, the replacement is **`Array (Maybe v)`** initialized with
`Array.repeat size Nothing` and populated with `Array.set i (Just v)`.

- Lookup: `Array.get i arr |> Maybe.andThen identity` (or a helper)
- Insert: `Array.set i (Just v) arr`
- Fold: `Array.foldl` / `Array.indexedMap` (skip `Nothing` entries)
- Size: Track separately or use `Array.length`

Where the type allows a sentinel value (e.g. integers where every index is guaranteed
populated), bare `Array v` without Maybe is preferred — see Algorithmic Rewrites below.

### Helper module

Create `compiler/src/Data/IntArray.elm` providing a **minimal** typed API:

```elm
module Data.IntArray exposing
    ( IntArray
    , empty, initialize
    , get, set
    , foldl, indexedMap
    , fromDict, toList
    , size
    )

type IntArray v = IntArray Int (Array (Maybe v))
-- Int = logical size (number of Just entries), tracked for O(1) size queries
```

This avoids sprinkling `Maybe.andThen identity` everywhere and provides a migration-
friendly API matching Dict's shape. The API is intentionally minimal — no `mergeWith`,
`filter`, or `traverse`. See Algorithmic Rewrites for why these aren't needed.

---

## Categories and Conversion Plan

### Phase 1: SpecId-keyed structures (highest impact)

**Category 1 — MonoGraph nodes & callEdges**

These are the largest Dicts (100s–1000s of entries) and are accessed throughout the
pipeline from monomorphization through MLIR generation.

**Current types in `Monomorphized.elm`:**
```elm
type MonoGraph = MonoGraph
    { nodes : Dict Int MonoNode
    , callEdges : Dict Int (List Int)
    , ...
    }
```

**Target types:**
```elm
type MonoGraph = MonoGraph
    { nodes : Array (Maybe MonoNode)      -- index = SpecId
    , callEdges : Array (Maybe (List Int)) -- index = SpecId
    , ...
    }
```

**callEdges consumption analysis:** The `List Int` values (neighbor SpecIds) are only
iterated, never looked up by SpecId within the list. Consumers:
- `Prune.elm`: `Dict.get specId callEdges` for DFS neighbors, then `Dict.filter` — both trivial with Array
- `MonoInlineSimplify.elm buildCallGraph`: read-only `Dict.get specId edges` — trivial with Array
No secondary conversion needed for the inner `List Int`.

**Files to change:**

| File | Dict Int field | Operations used | Notes |
|---|---|---|---|
| `AST/Monomorphized.elm` | `nodes`, `callEdges` | Type definition, `nodesToArray` (remove — now identity) | Central type change |
| `Monomorphize/State.elm` | `nodes`, `callEdges` | `Dict.empty`, `Dict.insert`, `Dict.get` | Currently `Data.Map.Dict Int Int` — convert directly |
| `Monomorphize/Monomorphize.elm` | `patchedNodes` (DMap) | `DMap.map`, `DMap.get`, `DMap.toList` | Convert DMap → Array in-place |
| `Monomorphize/Specialize.elm` | accumulator `(Dict Int MonoNode, MonoState)` | `Dict.insert`, `Dict.get` | Follow State.elm changes |
| `Monomorphize/Prune.elm` | `nodes`, `callEdges` | `Dict.filter`, `Dict.get`, `Dict.foldl` | `filter` → leave Nothing gaps (see below) |
| `Monomorphize/Analysis.elm` | `nodes` param | `Dict.foldl` | Trivial: `Array.foldl` skipping Nothing |
| `Generate/MLIR/Backend.elm` | `nodes` param | `Dict.size`, `Dict.foldl` | Remove `nodesToArray` call (already Array) |
| `Generate/MLIR/Context.elm` | `signatures` | `Dict.empty`, `Dict.insert`, `Dict.get`, `Dict.foldl` | SpecId-keyed |
| `GlobalOpt/AbiCloning.elm` | outer dict | `Dict.update` (nested) | Outer key = SpecId |

**Migration strategy — Option A (chosen):** Keep `MonoState.nodes` as Dict during worklist
processing (random inserts with unknown final size), then convert to Array when building
`MonoGraph`. This is essentially what `nodesToArray` does today. The MonoGraph consumers
(Prune, Analysis, GlobalOpt, Backend, Context) all switch to Array. The conversion cost is
O(n) and happens once.

**Prune.elm filter:** With Array, `Dict.filter` becomes
`Array.indexedMap (\i v -> if BitSet.member i live then v else Nothing)`. Dead entries
become `Nothing` rather than being removed. This is fine — all downstream consumers
already handle missing entries via `Array.get` returning `Nothing`.

### Phase 2: ABI Cloning

**Current type in `AbiCloning.elm`:**
```elm
Dict Int Int (Dict Int Int (List CaptureABI))
-- outer: SpecId → inner: param index → ABI list
```

**Target:** The outer dict follows Phase 1 (becomes part of the SpecId Array). The inner
dict (param index 0..arity-1) is tiny (typically 1-8 entries) and not worth converting.

**Recommendation:** Convert outer key (SpecId) to Array when Phase 1 is done. Leave inner
dict (param index) as Dict — too small to matter.

### Phase 3: Expression/Pattern NodeId dicts (HIGH impact)

**Current types:**
```elm
-- NodeIds.elm:
NodeVarMap = Dict Int Int IO.Variable    -- Data.Map wrapper

-- TypedCanonical.elm:
ExprTypes = Data.Map.Dict Int Int Can.Type
NodeTypes = Data.Map.Dict Int Int Can.Type

-- PostSolve.elm:
NodeTypes = Data.Map.Dict Int Int Can.Type

-- Solve.elm:
params/results: Data.Map.Dict Int Int Variable, Data.Map.Dict Int Int Can.Type
```

**Target:** `Array (Maybe v)` — IDs allocated from 0 by `Canonicalize.Ids.allocId`.
Convert directly from `Data.Map.Dict Int Int` to Array, skipping intermediate core Dict.

**Files to change:**

| File | Operations | Notes |
|---|---|---|
| `Type/Constrain/Typed/NodeIds.elm` | `Dict.insert`, `Dict.empty` | Builder; currently `Data.Map.Dict Int Int` |
| `AST/TypedCanonical.elm` | Type aliases only | Central type change |
| `Type/Solve.elm` | `IO.traverseMap`, result construction | Currently `Data.Map.Dict Int Int`; add local `traverseArrayMaybe` helper |
| `Type/PostSolve.elm` | `Data.Map.get`, `Data.Map.insert` (heavy — ~20 get, ~18 insert) | Currently `Data.Map.Dict Int Int`; most impactful file |

**`IO.traverseMap` resolution:** Solve.elm calls `IO.traverseMap` on
`nodeVars : Data.Map.Dict Int Int Variable` to convert each Variable to a Can.Type via IO
effects. With Array, add a local helper in Solve.elm:

```elm
traverseArrayMaybe : (a -> IO b) -> Array (Maybe a) -> IO (Array (Maybe b))
```

This is a mechanical transformation — iterate indices, apply the IO action to `Just`
entries, pass through `Nothing`. No algorithmic change.

**Priority: HIGH** — PostSolve has ~38 dict operations on NodeTypes for every module
compiled. These dicts can be large (thousands of entries for big modules).

### Phase 4: Staging system dicts (MEDIUM impact)

**Current types in `Staging/Types.elm` and `Staging/Solver.elm`:**
```elm
-- Types.elm:
Uf = { parent : Dict Int NodeId }
StagingGraph = { ..., nodeById : Dict Int Node, ... }
StagingSolution = { classSeg : Dict Int Segmentation, ... }

-- Solver.elm:
BuildState = { ..., nodeToClass : Dict Int ClassId, classMembers : Dict Int (List NodeId), ... }
```

**Target:** All keyed by NodeId or ClassId (contiguous from 0).

**Files to change:**

| File | Dict Int field | Operations |
|---|---|---|
| `Staging/Types.elm` | `Uf.parent`, `StagingGraph.nodeById`, `StagingSolution.classSeg` | Type definitions |
| `Staging/UnionFind.elm` | `parent` | `Dict.get`, `Dict.insert` (path compression + union) |
| `Staging/Solver.elm` | `nodeToClass`, `classMembers`, `classSeg` | `Dict.get`, `Dict.insert`, `Dict.update`, `Dict.foldl`, `Dict.empty` |
| `Staging/GraphBuilder.elm` | Indirectly via StagingGraph | Building graph |

**Union-Find optimization — sentinel Array (no Maybe):** The UF `parent` dict can become
`Array Int` (not `Array (Maybe Int)`) using a sentinel convention: `parent[i] == i` means
node `i` is its own root. Initialize with `Array.initialize n identity`. The `ufFind`
hot path becomes pure `Array.get`/`Array.set` with no Maybe unwrapping. Path compression
uses `Array.set node root parent`. See Algorithmic Rewrites section.

**Note:** `StagingGraph.nextNodeId` already tracks the allocation counter, so the Array
size is known at any point. `classMembers` size is bounded by `nextNodeId` (upper bound
on class count).

**Priority: MEDIUM** — staging runs per-function, and graphs are moderate size. UnionFind
is the hottest path here.

### Phase 5: Case/Jump target dicts (LOW impact)

**Current types:**
```elm
-- LocalOpt/Erased/Case.elm, LocalOpt/Typed/Case.elm:
targetCounts : Dict Int Int Int     -- branch index → count
choices : Dict Int Int Choice       -- branch index → choice

-- MLIR/Expr.elm, MLIR/TailRec.elm:
jumpLookup : Dict Int MonoExpr      -- branch index → body
updateDict : Dict Int MonoExpr      -- field index → update expr
```

**Target:** `Array` — these are small (2-20 entries), contiguous from 0.

**Files to change:**

| File | Operations | Notes |
|---|---|---|
| `LocalOpt/Erased/Case.elm` | `countTargets`, `createChoices`, `Dict.fromList`, `Dict.get` | Rewrite countTargets to thread accumulator (see below) |
| `LocalOpt/Typed/Case.elm` | Same as above | Mirror of Erased |
| `Generate/MLIR/Expr.elm` | `Dict.fromList`, `Dict.get` | Simple: `Array.fromList` + `Array.get` |
| `Generate/MLIR/TailRec.elm` | `Dict.fromList`, `Dict.get` | Simple: `Array.fromList` + `Array.get` |

**`countTargets` accumulator rewrite:** The current implementation builds and merges dicts
bottom-up via `Utils.mapUnionWith (+)`. This is rewritten to thread a bare `Array Int`
accumulator top-down — no merge needed. See Algorithmic Rewrites section.

**`jumpLookup` and `updateDict`:** These are built with `Dict.fromList` from indexed
branch lists and consumed with `Dict.get`. Trivially becomes `Array.fromList` +
`Array.get`. No algorithmic change.

**Priority: LOW** — these dicts are tiny. Convert for consistency, not performance.

---

## Algorithmic Rewrites

Several conversions benefit from deeper algorithm changes rather than mechanical
Dict→Array substitution. These eliminate the need for complex Array operations
(merge, filter, traverse) that would otherwise bloat the IntArray API.

### Rewrite 1: `countTargets` — accumulator eliminates mergeWith

**Current:** Recursively builds and merges `Dict Int Int` bottom-up:
```elm
countTargets : Opt.Decider Int -> Dict Int Int Int
countTargets decisionTree =
    case decisionTree of
        Leaf target -> Dict.singleton identity target 1
        Chain _ s f -> Utils.mapUnionWith identity compare (+) (countTargets s) (countTargets f)
        FanOut _ tests fb -> Utils.mapUnionsWith identity compare (+) (...)
```

**Rewritten:** Thread a bare `Array Int` (counts) top-down. The number of branches is
known from `indexedBranches` at the call site in `breakStuff`:
```elm
countTargets : Int -> Opt.Decider Int -> Array Int
countTargets numBranches decider =
    countTargetsHelp (Array.repeat numBranches 0) decider

countTargetsHelp : Array Int -> Opt.Decider Int -> Array Int
countTargetsHelp counts decider =
    case decider of
        Opt.Leaf target ->
            Array.set target (arrayGetOr 0 target counts + 1) counts
        Opt.Chain _ success failure ->
            countTargetsHelp (countTargetsHelp counts success) failure
        Opt.FanOut _ tests fallback ->
            List.foldl (\(_, sub) acc -> countTargetsHelp acc sub)
                (countTargetsHelp counts fallback)
                tests
```

`createChoices` then uses `Array.get target targetCounts` (returns `Int` directly, no
Maybe needed since every branch index has a count with default 0).

**Impact:** Eliminates all need for `mergeWith`/`mapUnionWith` on integer-keyed dicts.
Applied in both `LocalOpt/Erased/Case.elm` and `LocalOpt/Typed/Case.elm`.

### Rewrite 2: Staging UnionFind — sentinel Array eliminates Maybe

**Current:** `Uf = { parent : Dict Int NodeId }` with `Dict.get`/`Dict.insert`.
Missing key means "node is its own root".

**Rewritten:** `Uf = { parent : Array Int }` initialized with `Array.initialize n identity`.
Convention: `parent[i] == i` means node `i` is its own root.

```elm
ufFind : NodeId -> Uf -> ( NodeId, Uf )
ufFind node uf =
    case Array.get node uf.parent of
        Nothing -> ( node, uf )  -- out of bounds = root
        Just parent ->
            if parent == node then ( node, uf )
            else
                let (root, uf1) = ufFind parent uf
                    uf2 = if root /= parent then
                               { uf1 | parent = Array.set node root uf1.parent }
                           else uf1
                in (root, uf2)
```

No `Maybe` wrapping/unwrapping on the hot path. The `Array.get` still returns
`Maybe Int` from Elm's Array API, but the value itself is a bare `Int`, not
`Maybe Int` like `Array (Maybe v)` would require.

### Rewrite 3: `IO.traverseArrayMaybe` — local helper in Solve.elm

**Current:** `IO.traverseMap` over `Data.Map.Dict Int Int Variable`.

**Rewritten:** Local helper in Solve.elm:
```elm
traverseArrayMaybe : (a -> IO b) -> Array (Maybe a) -> IO (Array (Maybe b))
traverseArrayMaybe f arr =
    Array.foldl
        (\i maybeVal accIO ->
            case maybeVal of
                Nothing -> IO.map (Array.push Nothing) accIO
                Just val -> IO.map2 (\acc v -> Array.push (Just v) acc) accIO (f val)
        )
        (IO.pure Array.empty)
        arr
```

Mechanical transformation. Stays in Solve.elm to avoid touching the IO module.

---

## Implementation Order

```
Phase 1: SpecId nodes/callEdges  (HIGH impact, MEDIUM effort)
   ├─ 1a. Create Data/IntArray.elm minimal helper module
   ├─ 1b. Change MonoGraph type definition (nodes, callEdges)
   ├─ 1c. Update MonoState → MonoGraph boundary (replace nodesToArray)
   ├─ 1d. Update Prune.elm (Dict.filter → Array.indexedMap, leave Nothing gaps)
   ├─ 1e. Update Analysis.elm, Backend.elm, Context.elm, MonoInlineSimplify.elm
   └─ 1f. Update AbiCloning.elm outer dict (Phase 2)

Phase 3: Expression/Pattern NodeId dicts  (HIGH impact, MEDIUM effort)
   ├─ 3a. Change TypedCanonical.elm type aliases
   ├─ 3b. Update NodeIds.elm builder
   ├─ 3c. Add traverseArrayMaybe helper in Solve.elm, update boundary
   └─ 3d. Update PostSolve.elm (~38 operations)

Phase 4: Staging system dicts  (MEDIUM impact, LOW effort)
   ├─ 4a. Change Types.elm (Uf → sentinel Array Int, StagingGraph, StagingSolution)
   ├─ 4b. Update UnionFind.elm (Dict.get/insert → Array.get/set, no Maybe)
   └─ 4c. Update Solver.elm (nodeToClass, classMembers, classSeg → Array)

Phase 5: Case/Jump dicts  (LOW impact, LOW effort)
   ├─ 5a. Rewrite countTargets to thread accumulator Array Int (Erased/Case.elm + Typed/Case.elm)
   ├─ 5b. Update createChoices to use Array.get on counts
   ├─ 5c. Update MLIR/Expr.elm jumpLookup + updateDict (Dict.fromList → Array.fromList)
   └─ 5d. Update MLIR/TailRec.elm jumpLookup
```

---

## Resolved Decisions

1. **IntArray module scope:** Minimal — get/set/foldl/indexedMap/fromDict/size/toList.
   No mergeWith (countTargets uses accumulator rewrite), no filter (Prune leaves Nothing
   gaps), no traverse (local helper in Solve.elm).

2. **MonoState build strategy:** Option A — keep Dict during worklist, convert to Array
   at MonoGraph boundary. Minimal disruption, O(n) one-time cost.

3. **JS helpers + SourceMap:** Skipped — 8-entry static dicts and rarely-used source map
   dict are not worth the churn.

4. **Data.Map.Dict Int Int → Array:** Convert directly. No intermediate core Dict step.

5. **Prune.elm Dict.filter:** Leave Nothing gaps in Array. All downstream consumers
   already handle missing entries.

---

## Risk Assessment

- **Low risk:** The conversion is mechanical — same semantics, different container.
  The algorithmic rewrites (countTargets, UF sentinel) are small and well-contained.
- **Testing:** Existing E2E tests (`cmake --build build --target check`) and
  `elm-test-rs` cover all codepaths. No new tests needed beyond running the full suite.
  The UF sentinel convention will be validated by staging tests immediately.
- **Rollback:** Each phase is independent and can be reverted separately.
- **Performance:** Expected improvement in lookup-heavy paths (PostSolve, UnionFind,
  MLIR backend). No expected regressions — Array is strictly better for contiguous
  integer keys.
