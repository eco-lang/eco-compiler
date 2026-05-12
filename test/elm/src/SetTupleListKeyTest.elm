module SetTupleListKeyTest exposing (main)

{-| Set keyed by `( Int, List Int )`. Same F2 reach as
`DictTupleListKeyTest`: Set ordering uses `compare`, dedupe uses `==`.
Verify both axes.
-}

-- CHECK: keys: [(0, []), (0, [1]), (0, [2])]
-- CHECK: size: 3
-- CHECK: hasEmpty: True

import Html exposing (text)
import Set exposing (Set)


main =
    let
        emptyL : List Int
        emptyL = []

        s : Set ( Int, List Int )
        s =
            Set.fromList
                [ ( 0, [ 1 ] )
                , ( 0, emptyL )
                , ( 0, [ 2 ] )
                , ( 0, emptyL )
                ]

        _ = Debug.log "keys" (Set.toList s)
        _ = Debug.log "size" (Set.size s)
        _ = Debug.log "hasEmpty" (Set.member ( 0, emptyL ) s)
    in
    text "done"
