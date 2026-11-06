module HigherOrderFilterLikeFunctionTest exposing (..)

{-| A let-bound function that takes a predicate and a list, and keeps the list's head when the predicate holds, gives `[1]` for a predicate that always returns `True`.

`myFilter` looks only at the first element: it is not recursive, so it never
returns more than one element.

-}

-- CHECK: testValue: [1]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        myFilter pred list =
            case list of
                [] ->
                    []

                h :: t ->
                    if pred h then
                        [ h ]

                    else
                        []
    in
    myFilter (\_ -> Basics.True) [ 1 ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
