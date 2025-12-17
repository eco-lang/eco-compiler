module Compiler.Reporting.Suggest exposing (sort, rank)

{-| Suggestion generation based on string similarity.

This module uses Levenshtein distance to generate helpful suggestions when
the compiler encounters an unknown name, helping users quickly identify typos
and similar alternatives.


# Suggestions

@docs sort, rank

-}

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
    List.map addRank values |> List.sortBy Tuple.first
