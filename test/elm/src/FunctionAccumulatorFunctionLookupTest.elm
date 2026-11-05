module FunctionAccumulatorFunctionLookupTest exposing (..)

{-| Function lookup.

From `SourceIR.FunctionAccumulatorCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 15

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
    lookup 2 table 5 + lookup 9 table 1 + lookup 3 table 0


lookup : Int -> List ( Int, Int -> Int ) -> Int -> Int
lookup k entries =
    case entries of
        [] ->
            identity

        ( key, f ) :: rest ->
            if key == k then
                f

            else
                lookup k rest


table : List ( Int, Int -> Int )
table =
    [ ( 1, \x -> x + 1 ), ( 2, \x -> x * 2 ), ( 3, max 4 ) ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
