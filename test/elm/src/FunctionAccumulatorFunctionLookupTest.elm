module FunctionAccumulatorFunctionLookupTest exposing (..)

{-| Looking up a function in a list of key and function pairs, and applying the function found, gives the right result.

`lookup` walks a list of `( Int, Int -> Int )` pairs and returns the function
paired with the key, or `identity` when the key is absent. The table holds two
lambdas and the partial application `max 4`. The test logs
`lookup 2 table 5 + lookup 9 table 1 + lookup 3 table 0`, which is
10 + 1 + 4 = 15: a doubling lambda, `identity` for the missing key 9, and
`max 4 0`.

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
