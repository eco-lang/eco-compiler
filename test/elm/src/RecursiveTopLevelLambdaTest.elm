module RecursiveTopLevelLambdaTest exposing (..)

{-| A top-level value defined as a lambda that calls itself.

From `Compiler.LocalOpt.Typed.LocalOptPathsCoverageTest`, an elm-test unit test, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 4

import Basics exposing (..)
import Char exposing (Char)
import Html exposing (text)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple


testValue =
    count 0


count =
    \n ->
        if n > 3 then
            n

        else
            count (n + 1)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
