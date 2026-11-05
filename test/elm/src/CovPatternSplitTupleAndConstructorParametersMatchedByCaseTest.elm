module CovPatternSplitTupleAndConstructorParametersMatchedByCaseTest exposing (..)

{-| Split tuple and constructor parameters matched by case.

From `SourceIR.CovPatternCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


type Q
    = Q Bool Int


type P
    = P Int Float Int


testValue k =
    ( ( f3 ( k, 1.5, 2 ), f2 ( k, 3 ) ), ( g (P k 2.5 3), h (Q (k > 1) k) ) )


h : Q -> Int
h q =
    case q of
        Q True n ->
            n

        Q False n ->
            -n


g : P -> Int
g p =
    case p of
        P a b c ->
            a + c + round b


f2 : ( Int, Int ) -> Int
f2 t =
    case t of
        ( 0, b ) ->
            b

        ( a, b ) ->
            a * b


f3 : ( Int, Float, Int ) -> Int
f3 t =
    case t of
        ( a, b, c ) ->
            a + c + round b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
