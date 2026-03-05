# Stack-Safe Graph SCC Implementation

## Problem

Stage 5 of the bootstrap (MLIR self-compilation) crashes with `RangeError: Maximum call stack size exceeded`. The stack overflow originates in `Data.Graph.stronglyConnComp` from the `guida-lang/graph` package, called from `MonoInlineSimplify.buildCallGraph` (line 189). The monomorphized call graph has thousands of nodes, which exceeds JS's call stack limit.

## Root Cause

Two functions in `~/.elm/0.19.1/packages/guida-lang/graph/1.0.1/src/Data/Graph.elm` are not stack-safe:

### 1. `postorder` / `postorderF` (lines 542-549)

```elm
postorder : Tree a -> List a -> List a
postorder node =
    postorderF (Tree.children node) << (::) (Tree.label node)

postorderF : List (Tree a) -> List a -> List a
postorderF ts =
    List.foldr (<<) identity <| List.map postorder ts
```

This builds a **composition chain** (`f1 << f2 << f3 << ... << fN << identity`) proportional to the total number of tree nodes. When this composed function is finally applied (in `postOrd g = postorderF (dff g) []`), it produces a call stack N frames deep — one for each `<<` / `composeL` invocation.

Used by: `postOrd → scc → stronglyConnCompR → stronglyConnComp`

### 2. `dec` in `stronglyConnCompR` (lines 178-180)

```elm
dec : Tree Vertex -> List (Maybe ...) -> List (Maybe ...)
dec node vs =
    vertexFn (Tree.label node) :: List.foldr dec vs (Tree.children node)
```

This recursively traverses the SCC tree in pre-order. For a long path graph (1→2→3→...→N), the DFS tree is a chain of single-child nodes, and `dec` recurses N deep.

Used by: `stronglyConnCompR → stronglyConnComp`

### Why `dfs` is fine

The `dfs` function (line 493) is already stack-safe — it uses an explicit stack with a tail-recursive `go` loop. No change needed.

## Algorithm Overview

`stronglyConnComp` implements **Kosaraju's SCC algorithm**:

1. `graphFromEdges edges0` — build adjacency-list graph from triples *(safe)*
2. `transposeG g` — reverse all edges *(safe)*
3. `postOrd (transposeG g)` — compute post-order of reversed graph *(UNSAFE — postorderF)*
4. `dfs g (List.reverse postOrd)` — DFS in reverse post-order *(safe — dfs is stack-safe)*
5. Each resulting tree = one SCC, decoded via `dec` *(UNSAFE — dec)*

## Call Sites (6 total)

| # | File | Line | Node Type | Scope | Size |
|---|------|------|-----------|-------|------|
| 1 | `Builder/Build.elm` | 1241 | `ModuleName.Raw` | Global (all modules) | Large |
| 2 | `Canonicalize/Expression.elm` | 817 | `Binding` | Per-expression | Tiny (1-30) |
| 3 | `Canonicalize/Environment/Local.elm` | 191 | `A.Located Src.Alias` | Per-module | Small (10-100) |
| 4 | `Canonicalize/Module.elm` | 163 | `Can.Def` (all deps) | Per-module | Medium (50-200) |
| 5 | `Canonicalize/Module.elm` | 211 | `Can.Def` (direct deps) | Per-module subset | Tiny (1-10) |
| 6 | `GlobalOpt/MonoInlineSimplify.elm` | 189 | `SpecId` | Global (all specializations) | **Very large (1000s)** |

Call site 6 is the one that crashes. Call site 1 is also large but likely below the stack limit. All sites use the same API: `Graph.stronglyConnComp : List (node, comparable, List comparable) -> List (Graph.SCC node)`.

## Approach

**Create a local `Compiler.Graph` module** with stack-safe implementations. Change the 6 import sites from `Data.Graph as Graph` to `Compiler.Graph as Graph`.

Rationale:
- Cannot shadow a package module with a local one in Elm (ambiguity error)
- Modifying the package in `~/.elm/` cache is fragile (gets overwritten)
- A local module is self-contained and reproducible
- Import change is minimal: `Data.Graph` → `Compiler.Graph`

The local module will:
1. Define its own `SCC` type (identical to `Data.Graph.SCC`)
2. Re-use `Data.Graph.graphFromEdges`, `Data.Graph.dfs`, `Data.Graph.dff`, `Data.Graph.transposeG`
3. Provide stack-safe `postOrd` and `stronglyConnCompR`/`stronglyConnComp`

## Stack-Safe Implementations

### Stack-safe `postorderList`

Replace the composition-chain approach with an explicit work stack:

```elm
type PostOrderWork
    = Expand (Tree Vertex)
    | Yield Vertex


safePostorderList : List (Tree Vertex) -> List Vertex
safePostorderList trees =
    safePostorderHelp (List.map Expand trees) []


safePostorderHelp : List PostOrderWork -> List Vertex -> List Vertex
safePostorderHelp stack acc =
    case stack of
        [] ->
            List.reverse acc

        (Yield v) :: rest ->
            safePostorderHelp rest (v :: acc)

        (Expand tree) :: rest ->
            safePostorderHelp
                (List.map Expand (Tree.children tree)
                    ++ (Yield (Tree.label tree) :: rest)
                )
                acc
```

**Verification** for tree `1 [2 [], 3 []]`:
- Stack: `[Expand(1 [2,3])]`, acc: `[]`
- → `[Expand(2), Expand(3), Yield 1]`, acc: `[]`
- → `[Yield 2, Expand(3), Yield 1]`, acc: `[]`
- → `[Expand(3), Yield 1]`, acc: `[2]`
- → `[Yield 3, Yield 1]`, acc: `[2]`
- → `[Yield 1]`, acc: `[3, 2]`
- → `[]`, acc: `[1, 3, 2]`
- Result: `reverse [1, 3, 2]` = `[2, 3, 1]` ✓ (post-order)

**Complexity:** O(V+E) — each tree node creates exactly one `Expand` and one `Yield` work item. The `++` at each step is O(children), summing to O(E) total.

### Stack-safe `dec` (SCC tree flattening)

The `dec` function performs pre-order traversal. Replace with explicit stack:

```elm
flattenSCCTree : (Vertex -> Maybe node) -> Tree Vertex -> List node
flattenSCCTree vertexFn tree =
    flattenSCCTreeHelp vertexFn [ tree ] []


flattenSCCTreeHelp :
    (Vertex -> Maybe node)
    -> List (Tree Vertex)
    -> List node
    -> List node
flattenSCCTreeHelp vertexFn stack acc =
    case stack of
        [] ->
            List.reverse acc

        t :: rest ->
            let
                newAcc =
                    case vertexFn (Tree.label t) of
                        Just v ->
                            v :: acc

                        Nothing ->
                            acc
            in
            flattenSCCTreeHelp vertexFn (Tree.children t ++ rest) newAcc
```

**Verification** for tree `1 [2 [4], 3]` (pre-order = `[1, 2, 4, 3]`):
- Stack: `[1[2[4],3]]`, acc: `[]`
- → `[2[4], 3]`, acc: `[1]`
- → `[4, 3]`, acc: `[2, 1]`
- → `[3]`, acc: `[4, 2, 1]`
- → `[]`, acc: `[3, 4, 2, 1]`
- Result: `reverse [3, 4, 2, 1]` = `[1, 2, 4, 3]` ✓ (pre-order)

### Composed: `stronglyConnComp`

```elm
stronglyConnComp : List ( node, comparable, List comparable ) -> List (SCC node)
stronglyConnComp edges0 =
    List.map
        (\edge0 ->
            case edge0 of
                AcyclicSCC ( n, _, _ ) ->
                    AcyclicSCC n

                CyclicSCC triples ->
                    CyclicSCC (List.map (\( n, _, _ ) -> n) triples)
        )
        (stronglyConnCompR edges0)


stronglyConnCompR : List ( node, comparable, List comparable ) -> List (SCC ( node, comparable, List comparable ))
stronglyConnCompR edges0 =
    case edges0 of
        [] ->
            []

        _ ->
            let
                ( graph, vertexFn, _ ) =
                    Graph.graphFromEdges edges0

                forest =
                    safeScc graph

                decode tree =
                    let
                        v =
                            Tree.label tree
                    in
                    case ( Tree.children tree, mentionsItself graph v, vertexFn v ) of
                        ( [], True, _ ) ->
                            CyclicSCC (List.filterMap identity [ vertexFn v ])

                        ( [], False, Just vertex ) ->
                            AcyclicSCC vertex

                        ( ts, _, _ ) ->
                            CyclicSCC
                                (flattenSCCTree vertexFn tree)

                mentionsItself g v =
                    List.member v (Maybe.withDefault [] (Graph.Internal...))
            in
            List.map decode forest


safeScc : Graph.Graph -> List (Tree Graph.Vertex)
safeScc g =
    Graph.dfs g (List.reverse (safePostOrd (Graph.transposeG g)))


safePostOrd : Graph.Graph -> List Graph.Vertex
safePostOrd g =
    safePostorderList (Graph.dff g)
```

## Issue: `mentionsItself` needs `Internal.find`

The existing `stronglyConnCompR` uses `Internal.find v graph` (line 184) to check if a vertex has a self-loop. `Internal.find` is not publicly exported by `Data.Graph`.

**Options:**
1. Reimplement using `Data.Graph.edges` — filter for `(v, v)` self-loops. This is O(V+E) per SCC decode call, which is too expensive.
2. Pre-compute the self-loop set: `selfLoops = Set.fromList (List.filter (\(a,b) -> a == b) (Graph.edges graph))`. O(V+E) once, then O(log V) per check.
3. Use the adjacency list directly — but `Graph` is opaque.

**Decision:** Pre-compute self-loop set. O(V+E) upfront, O(log V) per vertex check.

```elm
selfLoopSet =
    List.foldl
        (\( a, b ) acc ->
            if a == b then
                Set.insert a acc
            else
                acc
        )
        Set.empty
        (Graph.edges graph)

mentionsItself v =
    Set.member v selfLoopSet
```

## Implementation Steps

### Step 1: Create `compiler/src/Compiler/Graph.elm`

New file with:
- `module Compiler.Graph exposing (SCC(..), stronglyConnComp, stronglyConnCompR, flattenSCC, flattenSCCs)`
- Same `SCC` type definition
- `stronglyConnComp` and `stronglyConnCompR` using stack-safe internals
- `flattenSCC` and `flattenSCCs` (trivial, same as original)
- Internal helpers: `safeScc`, `safePostOrd`, `safePostorderList`, `flattenSCCTree`
- Import `Data.Graph` (aliased) for `graphFromEdges`, `dfs`, `dff`, `transposeG`, `edges`
- Import `Tree`
- Import `Set`

### Step 2: Update 6 import sites

Change `import Data.Graph as Graph` to `import Compiler.Graph as Graph` in:

1. `compiler/src/Builder/Build.elm`
2. `compiler/src/Compiler/Canonicalize/Expression.elm`
3. `compiler/src/Compiler/Canonicalize/Environment/Local.elm`
4. `compiler/src/Compiler/Canonicalize/Module.elm`
5. `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

Note: `Module.elm` has 2 call sites but only 1 import to change.

### Step 3: Test

1. Run Elm frontend tests:
   ```bash
   cd /work/compiler
   npx elm-test-rs --project build-xhr --fuzz 1
   ```

2. Run E2E backend tests:
   ```bash
   cmake --build build --target check
   ```

3. Run bootstrap stages 1-4:
   ```bash
   export NODE_OPTIONS="--max-old-space-size=16384"
   cd /work/compiler
   ./scripts/build.sh bin
   ./scripts/build-self.sh bin
   ./scripts/build-verify.sh
   ```

### Step 4: Test Stage 5

```bash
cd /work/compiler/build-kernel
/usr/bin/time -v node --max-old-space-size=16384 bin/eco-boot-2-runner.js make \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1
```

## Verified Assumptions

1. **`Data.Graph` exposes enough API** — `graphFromEdges`, `dfs`, `dff`, `transposeG`, `edges` are all public. ✓
2. **`Tree` is available** via `zwilias/elm-rosetree` 1.5.0 (indirect dependency in both `build-kernel/elm.json` and `build-xhr/elm.json`). In Elm 0.19, indirect dependencies are importable. ✓
3. **All 5 import sites use ONLY `Graph.stronglyConnComp` and `Graph.SCC(..)`** (constructors `AcyclicSCC`, `CyclicSCC`). No other `Data.Graph` exports are used. Verified by grepping `Graph\.` across all files. ✓ This means `Compiler.Graph` only needs to expose `SCC(..)` and `stronglyConnComp`.
