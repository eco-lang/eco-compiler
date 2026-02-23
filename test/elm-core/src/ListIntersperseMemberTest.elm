module ListIntersperseMemberTest exposing (main)

-- CHECK: intersperse1: [1, 0, 2, 0, 3]
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
