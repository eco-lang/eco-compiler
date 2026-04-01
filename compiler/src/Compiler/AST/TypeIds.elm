module Compiler.AST.TypeIds exposing (MVarPh, MVarId, firstMVarId)

{-| Phantom-typed identifiers for type variables and monomorphization variables.

@docs MVarPh, MVarId, firstMVarId

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
