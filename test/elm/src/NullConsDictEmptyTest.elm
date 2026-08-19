module NullConsDictEmptyTest exposing (main)

{-| Null-cons embedding (HEAP_044 P3.0): RBEmpty is an embedded constant with
plain declaration index 1. Exercises embedded RBEmpty in tree slots, dictEq's
constant-terminated spine walk, shrink-back-to-empty, and kernel-built Dicts.
-}

-- CHECK: emptyEq: True
-- CHECK: removeToEmpty: True
-- CHECK: sizeAfterShrink: 0
-- CHECK: getMissing: Nothing
-- CHECK: foldSum: 6
-- CHECK: contentEq: True
-- CHECK: neqNonEmpty: False

import Dict
import Html exposing (text)


main =
    let
        _ =
            Debug.log "emptyEq" (Dict.empty == Dict.remove "k" (Dict.singleton "k" 1))

        _ =
            Debug.log "removeToEmpty"
                (Dict.isEmpty (Dict.remove 1 (Dict.singleton 1 "v")))

        shrunk =
            List.foldl Dict.remove
                (Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ])
                [ 1, 2, 3 ]

        _ =
            Debug.log "sizeAfterShrink" (Dict.size shrunk)

        _ =
            Debug.log "getMissing" (Dict.get 9 shrunk)

        -- Iteration over a tree whose leaves are all embedded RBEmpty slots.
        _ =
            Debug.log "foldSum"
                (Dict.foldl (\_ v acc -> v + acc)
                    0
                    (Dict.fromList [ ( "x", 1 ), ( "y", 2 ), ( "z", 3 ) ])
                )

        -- Content equality across different insertion-order tree shapes
        -- (dictEq spine walk with embedded empty subtrees).
        d1 =
            Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ]

        d2 =
            Dict.fromList [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ) ]

        _ =
            Debug.log "contentEq" (d1 == d2)

        _ =
            Debug.log "neqNonEmpty" (Dict.empty == Dict.singleton 1 "v")
    in
    text "done"
