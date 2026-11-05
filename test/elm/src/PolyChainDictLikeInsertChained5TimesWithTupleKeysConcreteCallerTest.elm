module PolyChainDictLikeInsertChained5TimesWithTupleKeysConcreteCallerTest exposing (..)

{-| Dict-like insert chained 5 times with tuple keys (concrete caller).

From `SourceIR.PolyChainCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 1

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


type MyDict k v
    = Empty
    | Entry k v (MyDict k v)


insert : k -> v -> MyDict k v -> MyDict k v
insert key val dict =
    Entry key val dict


size : MyDict k v -> Int
size d =
    case d of
        Empty ->
            0

        Entry _ _ _ ->
            1


testValue : Int
testValue =
    let
        d0 =
            Empty

        d1 =
            insert ( "k0", 0 ) 0 d0

        d2 =
            insert ( "k1", 1 ) 10 d1

        d3 =
            insert ( "k2", 2 ) 20 d2

        d4 =
            insert ( "k3", 3 ) 30 d3

        d5 =
            insert ( "k4", 4 ) 40 d4
    in
    size d5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
