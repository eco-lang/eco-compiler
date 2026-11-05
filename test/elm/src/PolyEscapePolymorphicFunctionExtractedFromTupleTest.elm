module PolyEscapePolymorphicFunctionExtractedFromTupleTest exposing (..)

{-| Polymorphic function extracted from tuple.

From `SourceIR.PolyEscapeCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
