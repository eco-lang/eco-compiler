module Compiler.AST.TypeIds exposing (MVarPh, MVarId)

{-| Phantom-typed identifiers for type variables and monomorphization variables.

@docs MVarPh, MVarId

-}

import Compiler.Data.Id exposing (Id)


{-| Phantom marker for monomorphization variable IDs.
-}
type MVarPh
    = MVarPh


{-| A monomorphization variable identifier used in Mono.MVar.
-}
type alias MVarId =
    Id MVarPh
