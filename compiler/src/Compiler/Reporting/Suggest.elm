module Compiler.Reporting.Suggest exposing
    ( rank
    , sort
    )

import Levenshtein



-- SORT


sort : String -> (a -> String) -> List a -> List a
sort target toString =
    List.sortBy
        (Levenshtein.distance (String.toLower target)
            << String.toLower
            << toString
        )



-- RANK


rank : String -> (a -> String) -> List a -> List ( Int, a )
rank target toString values =
    let
        toRank : a -> Int
        toRank v =
            Levenshtein.distance (String.toLower target) (String.toLower (toString v))

        addRank : a -> ( Int, a )
        addRank v =
            ( toRank v, v )
    in
    List.sortBy Tuple.first (List.map addRank values)
