module Compiler.AST.TypeIds exposing (MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId)

{-| Phantom-typed identifiers for type variables and monomorphization variables.

@docs MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId

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
one supply (LSS_003).
-}
type alias SrcLambdaId =
    Id LamPh


{-| The first SrcLambdaId in a sequential supply (value 0).
-}
firstSrcLambdaId : SrcLambdaId
firstSrcLambdaId =
    Id.first
