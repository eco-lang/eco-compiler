module PolyEscapePolymorphicFunctionExtractedFromTupleTest exposing (..)

{-| A function stored in a tuple and taken out again by a let-bound pattern-matching
helper can be applied: `first ( id, 0 ) 42` evaluates to 42.

`id` and `first` are unannotated local functions; `first` returns the first
component of a pair, here the function `id`, which is then applied to 42.

-}

-- CHECK: testValue: 42

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        id x =
            x

        first t =
            case t of
                ( fst, _ ) ->
                    fst
    in
    first ( id, 0 ) 42


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
