module EtaExpandStateFunctionSequenceTest exposing (..)

{-| A state-passing `sequence` written with `andThen` and `pure` over a function type alias, `St a = Int -> a`, whose definitions take more parameters than their annotations show.

`andThen` and `pure` are annotated against `St`, so each one's definition names the state as an extra parameter. `sequence []` falls to the wildcard branch, which runs `tick` and then returns `pure []`, so `List.length (sequence [] 0)` is 0.
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
