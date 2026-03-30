module Compiler.AST.TypeIds
    exposing
        ( TVarPh
        , TVarId
        , MVarPh
        , MVarId
        )

{-| Phantom-typed identifiers for type variables and monomorphization variables.

@docs TVarPh, TVarId, MVarPh, MVarId

-}

import Compiler.Data.Id exposing (Id)


{-| Phantom marker for type variable IDs in the TypedOptimized / Canonical layer.
-}
type TVarPh
    = TVarPh


{-| A globally unique type variable identifier.
-}
type alias TVarId =
    Id TVarPh


{-| Phantom marker for monomorphization variable IDs.
-}
type MVarPh
    = MVarPh


{-| A monomorphization variable identifier used in Mono.MVar.
-}
type alias MVarId =
    Id MVarPh
