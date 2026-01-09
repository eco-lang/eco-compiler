module Compiler.Reporting.Suggest exposing (sort, rank)

{-| Suggestion generation based on string similarity.

This module uses Levenshtein distance to generate helpful suggestions when
the compiler encounters an unknown name, helping users quickly identify typos
and similar alternatives.


# Suggestions

@docs sort, rank

-}

import Levenshtein



-- ====== SORT ======


{-| Sort a list of candidates by their Levenshtein distance from the target string.

The candidates are sorted in ascending order of edit distance, so the most similar
strings appear first. Case is ignored when computing distance.

-}
sort : String -> (a -> String) -> List a -> List a
sort target toString =
    List.sortBy
        (Levenshtein.distance (String.toLower target)
            << String.toLower
            << toString
        )



-- ====== RANK ======


{-| Rank candidates by their Levenshtein distance from the target string.

Returns a list of tuples where each tuple contains the edit distance and the original
candidate. The list is sorted by distance in ascending order, with the closest matches
first. Case is ignored when computing distance.

-}
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
