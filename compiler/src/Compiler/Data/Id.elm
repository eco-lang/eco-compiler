module Compiler.Data.Id
    exposing
        ( Id
        , Supply
        , newSupply
        , next
        , toComparable
        , fromComparable
        )


{-| Phantom-typed identifier. IDs are always >= 0 and strictly increasing
within a supply.
-}
type Id a
    = Id Int


{-| Opaque supply for allocating IDs of a particular phantom type.
-}
type Supply a
    = Supply Int


{-| Create a fresh supply starting at 0. -}
newSupply : Supply a
newSupply =
    Supply 0


{-| Allocate the next Id from a supply, returning the Id and the updated supply.
-}
next : Supply a -> ( Id a, Supply a )
next (Supply n) =
    ( Id n, Supply (n + 1) )


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
