module Compiler.Data.Map.Utils exposing (fromKeys, fromKeysA, any)

{-| Utility functions for working with dictionaries (maps).

This module provides helper functions for constructing and querying dictionaries.

@docs fromKeys, fromKeysA, any

-}

import Data.Map as Dict exposing (Dict)
import Task exposing (Task)
import Utils.Main as Utils



-- ====== FROM KEYS ======


{-| Creates a dictionary from a list of keys by applying a function to each key to generate its value.
-}
fromKeys : (comparable -> v) -> List comparable -> Dict comparable comparable v
fromKeys toValue keys =
    Dict.fromList identity (List.map (\k -> ( k, toValue k )) keys)


{-| Creates a dictionary from a list of keys by applying an asynchronous Task to each key to generate its value.
-}
fromKeysA : (k -> comparable) -> (k -> Task Never v) -> List k -> Task Never (Dict comparable k v)
fromKeysA toComparable toValue keys =
    Task.map (Dict.fromList toComparable) (Utils.listTraverse (\k -> Task.map (Tuple.pair k) (toValue k)) keys)



-- ====== ANY ======


{-| Checks if any value in the dictionary satisfies the given predicate.
-}
any : (v -> Bool) -> Dict c k v -> Bool
any isGood dict =
    Dict.foldl (\_ _ -> EQ) (\_ v acc -> isGood v || acc) False dict
