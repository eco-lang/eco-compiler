module ListAppendTest exposing (main)

{-| `List.append` and the `++` operator join two lists in order, and appending `[]` on the right leaves a list unchanged.
-}

-- CHECK: append1: [1,2,3,4]
-- CHECK: append_empty: [1,2]
-- CHECK: concat_op: [1,2,3]

import Html exposing (text)

main =
    let
        _ = Debug.log "append1" (List.append [1, 2] [3, 4])
        _ = Debug.log "append_empty" (List.append [1, 2] [])
        _ = Debug.log "concat_op" ([1] ++ [2, 3])
    in
    text "done"
