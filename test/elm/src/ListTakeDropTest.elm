module ListTakeDropTest exposing (main)

{-| List.take and List.drop return the expected prefix and suffix, including
for a count of zero.

`List.take 2` keeps the first two elements and `List.take 0` gives the empty
list; `List.drop 2` removes the first two and `List.drop 0` returns the list
unchanged.
-}

-- CHECK: take1: [1,2]
-- CHECK: take2: []
-- CHECK: drop1: [3,4,5]
-- CHECK: drop2: [1,2,3,4,5]

import Html exposing (text)


main =
    let
        _ = Debug.log "take1" (List.take 2 [1, 2, 3, 4, 5])
        _ = Debug.log "take2" (List.take 0 [1, 2, 3])
        _ = Debug.log "drop1" (List.drop 2 [1, 2, 3, 4, 5])
        _ = Debug.log "drop2" (List.drop 0 [1, 2, 3, 4, 5])
    in
    text "done"
