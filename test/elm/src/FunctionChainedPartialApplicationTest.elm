module FunctionChainedPartialApplicationTest exposing (..)

{-| Chained partial application.

From `SourceIR.FunctionCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        f =
            \a b c -> a

        p1 =
            f 1
    in
    p1 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
