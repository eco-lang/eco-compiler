module EtaExpandStateFunctionSequenceTest exposing (..)

{-| A state-function `sequence` built with `andThen` and `pure` over a function alias.

From `Compiler.PreMono.EtaExpandTest`, an elm-test unit test, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 0

import Basics exposing (..)
import Char exposing (..)
import Html exposing (text)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)


type alias St a =
    Int -> a


andThen : (a -> St b) -> St a -> St b
andThen f ma s0 =
    f (ma s0) s0


pure : a -> St a
pure x s =
    x


tick : St Int
tick s =
    s


plus : Int -> Int -> Int
plus a b =
    a


expensive : Int -> Int
expensive n =
    plus (plus n n) n


sequence : List (St Int) -> St (List Int)
sequence actions =
    case actions of
        [ one ] ->
            pure []

        [ one, two ] ->
            andThen (\x -> sequence [ two ]) one

        _ ->
            andThen (\x -> pure []) tick


testValue : Int
testValue =
    List.length (sequence [] 0)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
