module ListIndexedMapTest exposing (..)

{-| Top-level definitions named `map2`, `range` and `length` take precedence over
the same names exposed by `import List exposing (..)`.

The local versions are stubs (`map2` and `range` return `[]`, `length` returns
0), so the local `indexedMap`, built from them, returns `[]` for `[ 1, 2 ]`.

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
