module DictTupleListKeyTest exposing (main)

{-| A `Dict` keyed by `( Int, List Int )` orders a key with an empty list before
keys with non-empty lists, and can look that key up.

`compare` orders tuples field by field and lists element by element, with a
shorter prefix first, so `( 0, [] ) < ( 0, [ 1 ] ) < ( 0, [ 2 ] )`. The test
inserts the three keys out of order, logs `Dict.keys`, and checks that
`Dict.member` and `Dict.get` find the `( 0, [] )` entry.

-}

-- CHECK: keys: [(0,[]),(0,[1]),(0,[2])]
-- CHECK: hasEmpty: True
-- CHECK: emptyValue: Just "e"

import Dict exposing (Dict)
import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        d : Dict ( Int, List Int ) String
        d =
            Dict.fromList
                [ ( ( 0, [ 1 ] ), "a" )
                , ( ( 0, emptyL ), "e" )
                , ( ( 0, [ 2 ] ), "b" )
                ]

        _ = Debug.log "keys" (Dict.keys d)
        _ = Debug.log "hasEmpty" (Dict.member ( 0, emptyL ) d)
        _ = Debug.log "emptyValue" (Dict.get ( 0, emptyL ) d)
    in
    text "done"
