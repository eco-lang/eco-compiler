module CovLambdaSetFunctionsDestructuredFromTuplesAndRecordsTest exposing (..)

{-| Functions destructured from tuples and records.

From `SourceIR.CovLambdaSetCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 9

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


testValue : Int
testValue =
    let
        ( f, g ) =
            ( \x -> x + 1, \x -> x * 2 )

        { h } =
            { h = \x -> x - 3 }

        fs =
            [ f, g, h ]
    in
    List.foldl (\fn acc -> fn acc) 5 fs


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
