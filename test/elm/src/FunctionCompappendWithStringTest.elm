module FunctionCompappendWithStringTest exposing (..)

{-| compappend with String.

From `SourceIR.FunctionCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: "helloworld"

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


zsortConcat : compappend -> compappend -> compappend
zsortConcat a b =
    if a < b then
        a ++ b

    else
        b ++ a


testValue : String
testValue =
    zsortConcat "hello" "world"


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
