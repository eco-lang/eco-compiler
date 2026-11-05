module CovLambdaBoundaryCaseBoundaryUnderAFunctionAliasTest exposing (..)

{-| Case boundary under a function alias.

From `SourceIR.CovLambdaBoundaryCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 4

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


type alias F =
    Int -> Int


testValue : Int
testValue =
    choose 0 3


choose : Int -> F
choose n =
    case n of
        0 ->
            \a -> a + 1

        _ ->
            \b -> b * 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
