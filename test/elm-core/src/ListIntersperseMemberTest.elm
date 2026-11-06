module ListIntersperseMemberTest exposing (main)

{-| `List.intersperse` puts a separator between elements, and `List.member` reports whether a value is in a list.

`List.intersperse 0 [1,2,3]` gives `[1,0,2,0,3]`, with no separator at either end. `List.member` is checked for a value present (2) and one absent (5).

-}

-- CHECK: intersperse1: [1,0,2,0,3]
-- CHECK: member_yes: True
-- CHECK: member_no: False

import Html exposing (text)

main =
    let
        _ = Debug.log "intersperse1" (List.intersperse 0 [1, 2, 3])
        _ = Debug.log "member_yes" (List.member 2 [1, 2, 3])
        _ = Debug.log "member_no" (List.member 5 [1, 2, 3])
    in
    text "done"
