# Drop zwilias/elm-rosetree: Self-Contained Graph SCC

## Problem

`Compiler.Graph` currently delegates to `Data.Graph` for DFS (`dfs`/`dff`) which builds `Tree` structures (from `zwilias/elm-rosetree`), then immediately tears them apart with our own traversals. This wastes allocations and requires an unnecessary dependency.

## Approach

Rewrite `Compiler.Graph` to implement Kosaraju's SCC algorithm directly against an adjacency-list representation, using only `Array` and `Set` from `elm/core`. No `Tree`, no `Data.Graph`.

### Data representation

```elm
type alias AdjList = Array (List Int)
```

Vertices are 0..N-1 (contiguous integers). Built by sorting input triples by key and assigning sequential IDs. Binary search maps keys to vertex IDs.

### Algorithm (Kosaraju's, all tail-recursive)

1. **Build graph**: Sort triples by key, assign vertex IDs 0..N-1, build forward + transposed adjacency arrays via `Array.fromList`. Detect self-loops during construction.

2. **Reverse post-order on G^T**: Explicit DFS stack with `Enter v | Exit v` work items. `Enter` pushes children + `Exit`; `Exit` emits to accumulator. Naturally produces reverse post-order (no `List.reverse` needed).

3. **Collect SCCs on G**: Process vertices in reverse post-order. For each unvisited vertex, DFS collects all reachable unvisited vertices into one component. Classify: single vertex without self-loop → `AcyclicSCC`, otherwise → `CyclicSCC`.

### What's eliminated

- `import Tree` — no Tree allocation or traversal
- `import Data.Graph` — no delegation to external library
- `guida-lang/graph` dependency (was direct)
- `zwilias/elm-rosetree` dependency (was direct, previously indirect)

### What's kept

- Same public API: `SCC(..)`, `stronglyConnComp`, `stronglyConnCompR`, `flattenSCC`, `flattenSCCs`
- Same behavior: reverse topologically sorted SCCs
- Same complexity: O((V+E) log V) due to `Set` operations

## Steps

1. Rewrite `compiler/src/Compiler/Graph.elm` — self-contained Kosaraju's using `Array` + `Set`
2. Remove `guida-lang/graph` and `zwilias/elm-rosetree` from direct deps in `build-xhr/elm.json` and `build-kernel/elm.json` (move `guida-lang/graph` to indirect if needed by other packages, or remove entirely)
3. Run elm-test-rs and E2E tests
