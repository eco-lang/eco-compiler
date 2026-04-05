# Optimization of Solver State and Monomorphization per Elm Package
> High‑level design outline for reducing retained solver state size and shifting work from application builds to package builds.
---
## 1. Motivation

The current compiler architecture captures a **full type solver snapshot** per module after Hindley–Milner solving. This snapshot is stored in typed module artifacts and then used by the monomorphizer (MonoDirect) at application build time.【】
As the ecosystem grows and applications depend on more packages:
- **Memory pressure** increases because each loaded package module carries its entire solver snapshot (union‑find graph for all type variables used during typechecking).
- **Work at app compile time** also increases: MonoDirect must consider all polymorphic functions, including internal combinators that are only ever used at a small fixed set of monomorphic instantiations inside a package.

This document outlines a potential direction to:

1. **Compact solver snapshots per module** so they retain only the subset of the solver graph that later passes can actually query.
2. **Perform limited, intra‑package specialization** of internal polymorphic helpers at package build time, so applications do less monomorphization work and load smaller snapshots.

The design is intentionally high‑level; details may change as the compiler evolves.
---
## 2. Background
### 2.1 Current solver snapshot shape

After typechecking a module, the compiler runs the HM solver and captures its state as a `SolverSnapshot`【】:
```elm
type alias TypeVar =
    IO.Variable

type alias SolverState =
    { descriptors : Array IO.Descriptor
    , pointInfo : Array IO.PointInfo
    , weights : Array Int
    }

type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    , annotationVars : DMap.Dict String Name.Name TypeVar
    }
```

- `descriptors`, `pointInfo`, `weights` encode the **union‑find graph** of type variables and their solved structure.
- `nodeVars` maps TOpt node IDs to type variables.
- `annotationVars` maps annotated definitions to their principal type variables.
Later passes (PostSolve 2.0, MonoDirect) use:
- `exprVarFromId`, `resolveVariable`, `lookupDescriptor` to navigate the union‑find state.【】
- `withLocalUnification` / `specializeFunction` to perform **local** unification and obtain a `LocalView` with `typeOf` and `monoTypeOf` (and, in the newer version, a fallback `subst`) for type queries.【】
### 2.2 Current artifacts and MonoDirect

Typed module artifacts are written after typechecking and typed optimization:
```elm
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    , solverSnapshot : SolverSnapshot.SolverSnapshot
    , annotations : Dict Name Annotation
    , exports : InterfaceInfo
    }
【
```

At application build time:
- Artifacts for all reachable modules are loaded.
- `TOpt.LocalGraph`s are combined into `TOpt.GlobalGraph`s.
- MonoDirect (the new monomorphizer) is run over a **multi‑module** view:
  ```elm
  monomorphizeDirect :
      ModuleName
      -> Name
      -> Dict ModuleName ( TOpt.GlobalGraph, SolverSnapshot.SolverSnapshot )
      -> TypeEnv.GlobalTypeEnv
      -> Result String Mono.MonoGraph
  【
  ```

- MonoDirect uses the per‑module snapshots to specialize functions as they are requested, via a worklist and `withLocalUnification` for each specialization context.【】
---
## 3. Goals
### 3.1 Solver state footprint

- **Reduce the size of solver snapshots** stored in artifacts and loaded into memory for application builds.
- Keep snapshots sufficient for MonoDirect and any other artifact‑time consumers.
### 3.2 Application build cost

- **Shift work from app builds to package builds**:
  - Some monomorphization‑like work that is determined *purely* by package internals can be done once at package build time and cached.
- Ensure that application builds:
  - Load fewer, smaller snapshots,
  - Have fewer polymorphic functions that need runtime specialization.
### 3.3 Constraints

- Do not change externally visible semantics:
  - Public APIs of packages must remain purely annotated by canonical types; pre‑specialization must not change their behavior.
- Keep artifacts self‑contained:
  - An app build must be able to monomorphize using only the artifacts and standard type env; no need to re‑run full type inference on packages.
---
## 4. Design Overview

At a high level, we introduce **two orthogonal optimizations**, both per module/package:
1. **Snapshot Compaction**  
   After typechecking and PostSolve, but before writing `TypedModuleArtifact`, compute a *compacted* solver snapshot that keeps only type variables and descriptors reachable from IR metadata actually used by later passes.

2. **Intra‑Package Specialization of Internal Helpers**  
   During package build (while the full snapshot and TOpt graphs are available), perform limited specialization of internal polymorphic helpers whose instantiations are fully determined inside the package. Materialize monomorphic clones in TOpt, update call sites, and optionally drop unused polymorphic versions.

These optimizations are applied:

- At **package build time**, where work is cached in artifacts (`type-artifacts.dat`), and
- Per **module** within a package.

Application builds then:

- Load smaller snapshots and more monomorphic TOpt graphs,
- Run a single, multi‑module MonoDirect over the remaining polymorphic surface.
---
## 5. Snapshot Compaction
### 5.1 When and where

- **Timing:** After type inference and PostSolve 2.0, when we are about to construct `TypedModuleArtifact`.
- **Scope:** Per module, operating on its `SolverSnapshot` and `TOpt.LocalGraph`.
The lighter PostSolve 2.0 itself continues to operate on the **full** snapshot in memory; compaction only affects what is serialized and later re‑loaded by application builds.
### 5.2 Intuition

For a given module:
- Not all solver variables will ever be queried after typechecking:
  - Some belong to dead code eliminated in typed optimization.
  - Some local, internal variables are never reachable from any TOpt node that survives into the final `typedGraph`.
- MonoDirect and other artifact‑time consumers only reach the solver graph through:
  - `nodeVars` → expression/definition IDs that appear in `TOpt.LocalGraph`,
  - `annotationVars` → annotated global/port defs in this module.

Thus:

- If a type variable is **not reachable** from any `nodeVars`/`annotationVars` in the final TOpt graph, we can safely drop it from the persisted snapshot without changing the behavior of monomorphization or later type queries.
### 5.3 Root set and reachability

Define the **root set** R of type variables as:
- All `TypeVar`s in `snapshot.annotationVars`.
- All non‑`Nothing` `TypeVar`s in `snapshot.nodeVars` *restricted to node IDs that still exist in the final `typedGraph`*.

Then, in the union‑find graph:

- From each `v ∈ R`, we follow:
  - Parent links via `pointInfo` up to the root (`resolveVariable` semantics).【】
  - Descriptor edges: from each `IO.Descriptor` reachable from that root, to any child variables referenced in its type structure (function param/result vars, record field vars, alias inner vars, etc.).

The **reachable set** C is the closure of R under these edges. C contains exactly the variables that can:

- Be directly requested from IR metadata, or
- Appear in the structure of any type we reconstruct for those vars.
### 5.4 Compaction transform

Given R and C:
1. **Reindex C densely**:

   - Build a mapping `oldVar → newVar` (type variable indices).
   - Construct new arrays:
     - `descriptors' : Array IO.Descriptor`,
     - `pointInfo' : Array IO.PointInfo`,
     - `weights' : Array Int`,
     containing only entries for vars in C, with indices remapped.

2. **Rewrite parent links** in `pointInfo'`:

   - For any `Link oldParent`, set `Link newParent` where `newParent = remap(oldParent)`.

3. **Rewrite external mappings**:

   - `nodeVars'` has the same length as before; each `Just oldVar` becomes `Just newVar` using the remapping (or is set to `Nothing` if the node no longer exists in `typedGraph`).
   - `annotationVars'` remaps each `TypeVar` similarly.

4. **Emit compacted snapshot**:
   ```elm
   compactedSnapshot :
       { state =
           { descriptors = descriptors'
           , pointInfo  = pointInfo'
           , weights    = weights'
           }
       , nodeVars      = nodeVars'
       , annotationVars = annotationVars'
       }
   ```
### 5.5 Guarantees and invariants

Compaction must preserve:
- For every var `v` that appears in `nodeVars'` or `annotationVars'`:
  - `typeOf v` and `monoTypeOf v` obtained via `withLocalUnification` + `LocalView` on the compacted snapshot must be identical (up to alpha‑equivalence of type variables) to the result on the full snapshot.
- For any **local unification** starting from roots in `R`:
  - The behavior of `Unify.unify` on the local copy (`snapshotToIoState state`) must be the same, since it only interacts with descriptors/vars in C.

Conceptually, the compacted snapshot is a **quotient** of the full solver graph that is observationally equivalent for all artifact‑time consumers.
---
## 6. Intra‑Package Specialization of Internal Helpers
### 6.1 Motivation

Within a package:
- Some polymorphic helpers (e.g. `foldl`, `map2`, `filter`) are **not exported** from any exposed module.
- Their uses inside exposed modules may occur only at a **finite set of monomorphic instantiations** that are fully determined by the package code, e.g.:
  ```elm
  module ListHelpers exposing (foldl)
  foldl : (a -> b -> b) -> b -> List a -> b
  -- internal: not exposed from the package

  module PackageApi exposing (sum)
  sum : List Int -> Int
  sum ls = foldl (+) 0 ls
  ```

In this case:
- Every call to `foldl` inside the package has a concrete instantiation at `a = Int`, `b = Int`.
- No external consumer can call `foldl` directly (it’s not in any exposed module); only `sum` is exported.

We can:

- Specialize `foldl` at `(Int, Int)` *within the package*, and
- Rewrite `sum` to call the specialized helper, reducing polymorphism before the app build.
### 6.2 Scope and limitations

This optimization is intentionally limited:
- Only targets **internal** polymorphic helpers:
  - Functions not exported by any exposed module of the package.
- Only for **instantiations fully determined by the package**:
  - All call sites to the helper inside the package must be at known, monomorphic types (according to the module’s snapshot and TOpt graph).
- Does **not** attempt to pre‑specialize public APIs:
  - Exported functions remain as declared; app builds may still demand additional specializations (e.g. `map : (a -> b) -> List a -> List b`).

The result is partial monomorphization that is:

- Local to the package,
- Cacheable in package artifacts,
- Transparent to application semantics.
### 6.3 Implementation sketch at TOpt level

Rather than generating Mono at package build, we perform specialization *within TOpt*:
1. **Analyze call sites per helper**

   For each internal polymorphic function `f` in a module:

   - Use the module’s `TOpt.LocalGraph` + `SolverSnapshot` to discover all call sites of `f` and the concrete types at which it is instantiated.
   - If all instantiations are monomorphic, and the set is finite (typically small), record those instantiations.

2. **Generate monomorphic clones in TOpt**

   For each instantiation `τ` of `f`:

   - Clone `f`’s TOpt node to a new definition `f$τ` with:
     - Updated `Meta` / type metadata reflecting the monomorphic type,
     - A fresh `annotationVar` (or `Nothing` if treated as monomorphic),
     - Possibly updated names to avoid pollution.

   This is a type‑directed transformation driven by the snapshot; it stays in the TOpt IR.

3. **Rewrite internal call sites**

   - Replace each call to `f` at instantiation `τ` with a call to `f$τ`.
   - If `f` is never referenced polymorphically (only via monomorphic clones), mark `f` as dead code.

4. **Dead‑code eliminate unused polymorphic helper**

   - Run or reuse existing TOpt DCE to drop internal defs that have no call sites (e.g. the original `foldl` if only `foldl$int` is used).

5. **Update solver snapshot (optional)**

   - The full snapshot still contains polymorphic structure for `f`.
   - After TOpt is rewritten, that polymorphic structure may become unreachable from any `nodeVars`/`annotationVars`, and will be **trimmed automatically** by the snapshot compaction step described earlier.
### 6.4 Effect on monomorphization

From the app build’s perspective:
- The TOpt graphs loaded from package artifacts already use monomorphic clones for many internal helpers.
- MonoDirect sees:
  - Fewer polymorphic functions (internal combinators have been “consumed” into monomorphic defs),
  - Simpler call graphs from public APIs down into internal implementation.

As a result:

- MonoDirect’s worklist contains fewer polymorphic specialization keys,
- Snapshot queries are concentrated on a smaller polymorphic surface per package.
---
## 7. Interplay Between Compaction and Intra‑Package Specialization

The two optimizations are complementary:
1. **Intra‑package specialization reduces polymorphism**:
   - Internal helpers that previously contributed many type variables to the solver graph become monomorphic clones in TOpt.
   - Their polymorphic structures in the solver snapshot become reachable only through nodes that may now be dead.

2. **Snapshot compaction removes unreachable solver state**:
   - After TOpt is transformed, `nodeVars`/`annotationVars` reference a smaller set of type variables.
   - The compaction pass can aggressively drop any solver vars that are not reachable from the transformed graph.

Net effect per package module:

- Smaller `TOpt.LocalGraph` (fewer polymorphic defs).
- Smaller `SolverSnapshot` in artifacts.
- Less work at application build across all apps that depend on the package.
---
## 8. Integration with the Existing Pipeline

Per module in a package build:
1. **Typecheck + HM solve**:
   - Run `Solve.runWithIds` to obtain `solverState`, `nodeVars`, `annotationVars`, etc.【】
   - Build full `SolverSnapshot` via `fromSolveResult`.【】

2. **PostSolve 2.0 (snapshot‑driven)**:
   - Use full snapshot + Canonical to compute repaired `nodeTypes`, kernel env, etc.【】

3. **TypedOptimized (TOpt)**:
   - Produce `TOpt.LocalGraph`.

4. **Intra‑module / intra‑package specialization (optional phase)**:
   - If enabled, perform internal specialization of helpers at the TOpt level using the snapshot.

5. **Snapshot compaction**:
   - Compute compacted `SolverSnapshot` as described in Section 5.

6. **Write `TypedModuleArtifact`**:
   - Store `typedGraph`, `typeEnv`, compacted `solverSnapshot`, `annotations`, `exports`.【】

At application build:

- Load only artifacts for reachable modules.
- Reconstruct `TOpt.GlobalGraph` and per‑module snapshots (already compacted).
- Run multi‑module MonoDirect as designed.【】
---
## 9. Risks and Open Questions
### 9.1 Complexity vs. benefit of compaction

- **Complexity:**
  - Requires robust descriptor‑graph traversal to compute reachability.
  - Must update all arrays and mappings consistently when reindexing type vars.
- **Benefit:**
  - Depends on how many solver vars are truly unreachable from final `TOpt.LocalGraph`.
  - Needs empirical measurement on real packages to see memory/time impact.
### 9.2 Correctness of intra‑package specialization

- Must ensure we only pre‑specialize uses that are:
  - Entirely within the package,
  - At fully monomorphic instantiations.
- Need invariants/tests that guarantee:
  - Public APIs remain unchanged,
  - Pre‑specialized helpers remain equivalent to the polymorphic definitions they replace.
### 9.3 Interaction with future tooling

- If IDE tooling or other external tools rely on full snapshots to query “type of any expression”, compacted snapshots might be too small.
- Possible mitigations:
  - Keep full snapshots only in editor/debug builds,
  - Or provide an alternate artifact format for tools.
### 9.4 Packages with heavy type‑level programming

- Some packages may intentionally expose polymorphic combinators heavily.
- Internal specialization opportunities may be limited.
- Need heuristics to avoid over‑specializing or blowing up code size with many clones.
---
## 10. Summary

This document outlines a potential direction to keep solver state size manageable and reduce monomorphization work at application build time by:
1. **Compacting solver snapshots per module** before artifacts are written, keeping only the subset of the union‑find graph that later passes can observe.
2. **Pre‑specializing internal polymorphic helpers within packages** at the TOpt level, when all their instantiations are fully determined internally.

Both optimizations are:

- **Per‑module / per‑package**, fitting the existing artifact model.
- **Orthogonal** to the main MonoDirect design, which remains a multi‑module monomorphizer driven by per‑module snapshots.
- **Cache‑friendly**, since package artifacts are reused across many app builds.

The design is intentionally high‑level and leaves room for experimentation and refinement as the compiler’s type and monomorphization pipelines solidify.
