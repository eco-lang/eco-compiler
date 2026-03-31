module Compiler.Data.Id exposing (Id, toComparable, fromComparable)

{-| Phantom-typed unique identifier supply.

@docs Id, toComparable, fromComparable

-}


{-| Phantom-typed identifier. IDs are always >= 0 and strictly increasing
within a supply.
-}
type Id a
    = Id Int


{-| Get a stable Int suitable for Dict keys, Array indices, serialization, etc.

Callers must NOT assign semantic meaning to specific ranges; use
side tables keyed by Id instead.

-}
toComparable : Id a -> Int
toComparable (Id n) =
    n


{-| Reconstruct an Id from a comparable Int.
Used internally for deterministic hash-based Id allocation.
-}
fromComparable : Int -> Id a
fromComparable n =
    Id n
