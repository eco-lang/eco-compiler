module SetTupleListKeyTest exposing (main)

{-| A `Set` of `( Int, List Int )` tuples orders its elements with `compare` and drops duplicates by equality, including when the list component is empty.

The set is built from four tuples, two of them the same `( 0, [] )`. The test
checks that `Set.toList` gives the three distinct tuples ordered by their lists
(`[]` before `[1]` before `[2]`), that `Set.size` is 3, and that
`Set.member ( 0, [] )` is `True`.

-}

-- CHECK: keys: [(0,[]),(0,[1]),(0,[2])]
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
