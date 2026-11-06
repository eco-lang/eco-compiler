module CovLambdaSetFunctionsInRecordsTuplesAndMaybeTest exposing (..)

{-| Functions stored in record fields, tuples and a `Maybe`, taken out again and applied.

The four terms are `dbl 3 = 6`, `inc 1 = 2`, `(\x -> x - 1) 2 = 1` and `inc 4 = 5`, which sum
to `14`.

-}

-- CHECK: testValue: 14

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


type alias Ops =
    { inc : Int -> Int, dbl : Int -> Int }


testValue : Int
testValue =
    run maybeF 3 + Tuple.first pairF 1 + Tuple.second pairF 2 + run (Just (Tuple.first pairF)) 4


run : Maybe (Int -> Int) -> Int -> Int
run m x =
    case m of
        Just f ->
            f x

        Nothing ->
            x


maybeF : Maybe (Int -> Int)
maybeF =
    Just ops.dbl


pairF : ( Int -> Int, Int -> Int )
pairF =
    ( ops.inc, \x -> x - 1 )


ops : Ops
ops =
    { inc = \x -> x + 1, dbl = \x -> x * 2 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
