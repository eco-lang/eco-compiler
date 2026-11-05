module ListIndexedMapTest exposing (..)

{-| indexedMap.

From `SourceIR.ListCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: []

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


map2 : (a -> b -> c) -> List a -> List b -> List c
map2 f xs ys =
    []


range : Int -> Int -> List Int
range lo hi =
    []


length : List a -> Int
length xs =
    0


indexedMap : (Int -> a -> b) -> List a -> List b
indexedMap f xs =
    map2 f (range 0 (length xs - 1)) xs


testValue : List Int
testValue =
    indexedMap (\i x -> i) [ 1, 2 ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
