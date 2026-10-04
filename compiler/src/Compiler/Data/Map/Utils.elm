module Compiler.Data.Map.Utils exposing (any)

{-| A helper over `Data.Map` dictionaries that `Data.Map` itself does not
provide: asking whether any value satisfies a predicate.

@docs any

-}

import Data.Map as Dict exposing (Dict)


{-| Returns whether `isGood` holds for at least one value in `dict`, and
`False` for an empty dictionary. Keys are not consulted.

`isGood` is applied to every value, even after one has satisfied it.

-}
any : (v -> Bool) -> Dict c k v -> Bool
any isGood dict =
    Dict.foldl (\_ v acc -> isGood v || acc) False dict
