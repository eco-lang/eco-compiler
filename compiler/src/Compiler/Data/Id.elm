module Compiler.Data.Id exposing (Id, toComparable, first, succ)

{-| Phantom-typed unique identifier supply.

IDs are opaque and can only be created sequentially via `first` and `succ`.
This ensures all IDs are non-negative and globally unique when allocated
from a single supply.

@docs Id, toComparable, first, succ

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


{-| The first Id in a sequential supply (value 0).
-}
first : Id a
first =
    Id 0


{-| The next Id after the given one.
-}
succ : Id a -> Id a
succ (Id n) =
    Id (n + 1)
