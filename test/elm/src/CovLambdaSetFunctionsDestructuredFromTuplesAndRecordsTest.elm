module CovLambdaSetFunctionsDestructuredFromTuplesAndRecordsTest exposing (..)

{-| Lambdas taken out of a tuple and a record by destructuring `let` patterns, put in a list and
applied in turn.

Folding `[ (+1), (*2), (-3) ]` over `5` gives `6`, `12`, then `9`.

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
