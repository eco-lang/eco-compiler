module Compiler.Reporting.Suggest exposing
    ( distance
    , rank
    , sort
    )

import Levenshtein



-- DISTANCE


distance : String -> String -> Int
distance =
    Levenshtein.distance



-- SORT


sort : String -> (a -> String) -> List a -> List a
sort target toString =
    List.sortBy
        (distance (String.toLower target)
            << String.toLower
            << toString
        )



-- RANK


rank : String -> (a -> String) -> List a -> List ( Int, a )
rank target toString values =
    let
        toRank : a -> Int
        toRank v =
            distance (String.toLower target) (String.toLower (toString v))

        addRank : a -> ( Int, a )
        addRank v =
            ( toRank v, v )
    in
    List.sortBy Tuple.first (List.map addRank values)
