module ListHeadTailTest exposing (main)

{-| `List.head` and `List.tail` return `Just` for a non-empty list and `Nothing` for
the empty list.
-}

-- CHECK: head1: Just 1
-- CHECK: head2: Nothing
-- CHECK: tail1: Just [2,3]
-- CHECK: tail2: Nothing

import Html exposing (text)


main =
    let
        _ = Debug.log "head1" (List.head [1, 2, 3])
        _ = Debug.log "head2" (List.head [])
        _ = Debug.log "tail1" (List.tail [1, 2, 3])
        _ = Debug.log "tail2" (List.tail [])
    in
    text "done"
