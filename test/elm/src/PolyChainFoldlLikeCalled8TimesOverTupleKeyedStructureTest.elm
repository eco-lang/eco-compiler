module PolyChainFoldlLikeCalled8TimesOverTupleKeyedStructureTest exposing (..)

{-| foldl-like called 8 times over tuple-keyed structure.

From `SourceIR.PolyChainCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 0

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


type Global
    = Global


myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl f init xs =
    init


step : ( List String, Global ) -> Int -> Int
step entry acc =
    acc


testValue : Int
testValue =
    let
        entries =
            []

        r1 =
            myFoldl step 0 entries

        r2 =
            myFoldl step r1 entries

        r3 =
            myFoldl step r2 entries

        r4 =
            myFoldl step r3 entries

        r5 =
            myFoldl step r4 entries

        r6 =
            myFoldl step r5 entries

        r7 =
            myFoldl step r6 entries

        r8 =
            myFoldl step r7 entries
    in
    r8


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
