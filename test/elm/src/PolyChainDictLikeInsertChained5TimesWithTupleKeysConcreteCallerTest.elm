module PolyChainDictLikeInsertChained5TimesWithTupleKeysConcreteCallerTest exposing (..)

{-| Tests a polymorphic `insert` on a list-like dictionary type, called five
times in a chain from a function with concrete `( String, Int )` keys and
`Int` values.

`size` looks only at the outermost constructor, returning 1 for any `Entry`,
so the logged value is 1 rather than the number of entries.

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
