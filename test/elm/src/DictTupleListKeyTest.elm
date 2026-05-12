module DictTupleListKeyTest exposing (main)

{-| Dict keyed by `( Int, List Int )` — Dict.fromList uses `compare`
internally, which routes through the buggy `compareUnboxableSlot` path
when comparing keys whose second tuple field is `[]` vs a heap list.

Elm semantics: `(0, []) < (0, [1])`. Therefore Dict.toList ordering
should be: `(0, [])`, `(0, [1])`, `(0, [2])`. The F2 bug places
Nil-keyed entries last because Nil's `constant=5` sorts as GT against
heap pointers (`constant=0`).
-}

-- CHECK: keys: [(0, []), (0, [1]), (0, [2])]
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
