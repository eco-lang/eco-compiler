module Compiler.Data.Map.Utils exposing (any)

{-| Utility functions for working with dictionaries (maps).

This module provides helper functions for constructing and querying dictionaries.

@docs any

-}

import Data.Map as Dict exposing (Dict)



-- ====== FROM KEYS ======
-- ====== ANY ======


{-| Checks if any value in the dictionary satisfies the given predicate.
-}
any : (v -> Bool) -> Dict c k v -> Bool
any isGood dict =
    Dict.foldl (\_ _ -> EQ) (\_ v acc -> isGood v || acc) False dict
