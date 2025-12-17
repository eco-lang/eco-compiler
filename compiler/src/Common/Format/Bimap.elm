module Common.Format.Bimap exposing
    ( Bimap
    , fromList
    )

import Data.Map as Map exposing (Dict)


{-| A bidirectional map that maintains mappings in both directions.
Allows efficient lookup from a to b and from b to a.
-}
type Bimap a b
    = Bimap (Dict String a b) (Dict String b a)


{-| Create a bidirectional map from a list of pairs.
Requires functions to convert keys to comparable strings for both directions.
-}
fromList : (a -> String) -> (b -> String) -> List ( a, b ) -> Bimap a b
fromList toComparableA toComparableB list =
    Bimap (Map.fromList toComparableA list)
        (Map.fromList toComparableB (List.map (\( a, b ) -> ( b, a )) list))
