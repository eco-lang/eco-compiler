module Compiler.Reporting.Suggest exposing (sort, rank)

{-| When a report names something the compiler could not find, such as a
misspelled variable, field or module, it can offer the nearest known names as
suggestions. This module decides which known names are nearest.

Nearness is the number `Levenshtein.distance`, from the `dasch/levenshtein`
package, gives: a count of single-character insertions, deletions and
substitutions that turn one string into the other. It can be more than the
fewest such edits: it gives 2 for "a" and "xa". Case is ignored, because both
strings are lower-cased before they are measured.

Both functions take the name that was given, a way to turn a candidate into a
string, and the candidates, and return every candidate ordered from nearest to
furthest. Neither drops a candidate, however distant. Deciding how many
suggestions to show, or how distant is too distant, is left to the caller.

@docs sort, rank

-}

import Levenshtein


{-| Returns the candidates ordered from nearest to furthest from `target`,
measured on the lower-cased `target` and the lower-cased string `toString` gives
for each candidate.
-}
sort : String -> (a -> String) -> List a -> List a
sort target toString =
    List.sortBy
        (Levenshtein.distance (String.toLower target)
            << String.toLower
            << toString
        )


{-| Returns the candidates as `sort` does, each paired with its distance from
`target`, so that a caller can cut the list off at a distance.
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
