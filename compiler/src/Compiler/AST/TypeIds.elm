module Compiler.AST.TypeIds exposing
    ( MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId
    , ArrowPh, ArrowId, firstArrowId, ArrowSlot(..)
    )

{-| Phantom-typed identifiers for type variables and monomorphization variables.

@docs MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId
@docs ArrowPh, ArrowId, firstArrowId, ArrowSlot

-}

import Compiler.Data.Id as Id exposing (Id)


{-| Phantom marker for monomorphization variable IDs.
-}
type MVarPh
    = MVarPh


{-| A monomorphization variable identifier used in Mono.MVar.
-}
type alias MVarId =
    Id MVarPh


{-| The first MVarId in a sequential supply (value 0).
-}
firstMVarId : MVarId
firstMVarId =
    Id.first


{-| Phantom marker for source-lambda identifiers (LSS member ids).
-}
type LamPh
    = LamPh


{-| Per-run identity of a source-level function value: a syntactic lambda
(stamped by `AssignMVarIds` in Phase-0) or an interned non-lambda function
value (MonoSolver engine interning). Dense from 0; the two producers share
one supply (LSS\_003).
-}
type alias SrcLambdaId =
    Id LamPh


{-| The first SrcLambdaId in a sequential supply (value 0).
-}
firstSrcLambdaId : SrcLambdaId
firstSrcLambdaId =
    Id.first


{-| Phantom marker for arrow (`Can.TLambda`) identity.
-}
type ArrowPh
    = ArrowPh


{-| Per-run identity of a **syntactic arrow occurrence**
(`plans/lss-unknown-elimination.md` Phase 2a).

The paper's `ℱ(t₁→t₂) = ℱ(t₁) --α--> ℱ(t₂)` assigns one lambda-set variable per
arrow of a type. Eco's existing type identity is entirely NAME-based
(`AssignMVarIds.ensureBinder` resolves `TVar name` through `schemeRootsForDef`),
and **arrows have no name** — so before this id, every load of an arrow minted a
DISJOINT set slot and the sets could not travel with the type. That is LSS\_006's
per-load fragmentation, and it is what ~11 hand-written transport artifacts
exist to bridge.

Resolved ONCE, in `AssignMVarIds.rewriteCanType` — either from the arrow's
solver root (Phase 2b, when `Compiler.Compile` stamped a `SolverRoot`) or, as
the fallback, freshly minted per syntactic OCCURRENCE (Phase 2a). Identity is
never by name (two arrows in `(a -> b) -> a -> b` would collapse) and never
structural (two distinct `Int -> Int` would collapse).

-}
type alias ArrowId =
    Id ArrowPh


{-| The first ArrowId in the global per-arrow supply (`AssignMVarIds.nextArrow`).
-}
firstArrowId : ArrowId
firstArrowId =
    Id.first


{-| What a `Can.TLambda` carries in its identity slot. **Its meaning is
PHASE-DEPENDENT, exactly as the `id` parameter of `Can.Type id` is** (`Name`
before `AssignMVarIds`, `MVarId` after), and the three constructors make that
impossible to confuse:

  - `NoArrow` — unstamped. A type built before the type checker ran, or by one
    of the post-`AssignMVarIds` constructors that has no id supply
    (`Analysis.convertCanTypeNameToMVarId`, `TypeSubst.buildCurriedCanType`,
    `Specialize.buildFuncType`). **Must ALWAYS MISS and NEVER be RECORDED in an
    arrow memo** — recording it would collapse every unstamped arrow of a type
    into one slot, the exact unsoundness structural keying would have. It is a
    nullary constructor, so it is an embedded constant and costs no allocation
    (REP\_CONSTANT\_001) — which is why this is a union rather than a `Maybe`.

  - `SolverRoot idx` — **Phase 2b, `Can.Type Name` only.** The union-find root
    index of this arrow in the OWNING MODULE's solve, stamped by
    `Compiler.Compile` while `solverState` is still live. Module-local: each
    module numbers its `Pt` from zero, so it is only ever meaningful together
    with the home module of the global that carries it. `AssignMVarIds` resolves
    the pair `(moduleKey, idx)` to a global `ArrowId`, mirroring
    `ensureMVarIdForRoot`.

  - `Arrow id` — **`Can.Type MVarId` only.** The global per-arrow identity that
    `Store.loadTypeC` memoises set slots by.

-}
type ArrowSlot
    = NoArrow
    | SolverRoot Int
    | Arrow ArrowId
