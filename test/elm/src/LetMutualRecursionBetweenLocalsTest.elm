module LetMutualRecursionBetweenLocalsTest exposing (..)

{-| Two local functions of one `let` calling each other.

From `Compiler.LocalOpt.Typed.LocalOptPathsCoverageTest`, an elm-test unit test, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 22

import Basics exposing (..)
import Char exposing (Char)
import Html exposing (text)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple


testValue : Int
testValue =
    let
        f k =
            if k > 10 then
                g k

            else
                f (k + 1)

        g k =
            if k > 20 then
                k

            else
                f (k * 2)
    in
    f 0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
