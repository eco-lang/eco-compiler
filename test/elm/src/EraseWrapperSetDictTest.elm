module EraseWrapperSetDictTest exposing (main)

{-| elm/core's `Set`, itself a wrapper around a `Dict`, and a `Dict` whose
values are wrappers, under `EraseWrappers` (plans/constructor-representation-levels.md
E1a): set operations, set equality (two sets built in different orders, whose
trees may differ, are equal), membership, folding, and `Dict` lookups and
updates of wrapped values. The results are the same whether or not the wrappers
are erased.

-}

-- CHECK: union: [1,2,3,4]
-- CHECK: diff: [1]
-- CHECK: member: True
-- CHECK: setEq: True
-- CHECK: setNeq: False
-- CHECK: setShow: Set.fromList [1,2,3]
-- CHECK: dictGet: Just (Tag "b")
-- CHECK: dictUpdate: [(1,Tag "a!"),(2,Tag "b")]
-- CHECK: dictFold: "ab"
-- CHECK: dictEq: True

import Dict
import Html exposing (text)
import Set


type Tag
    = Tag String


unTag : Tag -> String
unTag (Tag s) =
    s


main =
    let
        a =
            Set.fromList [ 1, 2, 3 ]

        b =
            Set.fromList [ 4, 3, 2 ]

        _ =
            Debug.log "union" (Set.toList (Set.union a b))

        _ =
            Debug.log "diff" (Set.toList (Set.diff a b))

        _ =
            Debug.log "member" (Set.member 2 a)

        _ =
            Debug.log "setEq" (Set.fromList [ 3, 1, 2 ] == a)

        _ =
            Debug.log "setNeq" (a == b)

        _ =
            Debug.log "setShow" a

        d =
            Dict.fromList [ ( 1, Tag "a" ), ( 2, Tag "b" ) ]

        _ =
            Debug.log "dictGet" (Dict.get 2 d)

        _ =
            Debug.log "dictUpdate" (Dict.toList (Dict.update 1 (Maybe.map (\(Tag s) -> Tag (s ++ "!"))) d))

        _ =
            Debug.log "dictFold" (Dict.foldl (\_ t acc -> acc ++ unTag t) "" d)

        _ =
            Debug.log "dictEq" (Dict.fromList [ ( 2, Tag "b" ), ( 1, Tag "a" ) ] == d)
    in
    text "done"
