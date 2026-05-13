module NotEqualBoolListMemberTest exposing (main)

{-| `not (List.member …)` over Bool. `List.member` is implemented via
`==`, so this test verifies the inverted assertion still holds — and
will fail today because `True == False` returns True at top level.
-}

-- CHECK: notMemberFalseInTrues: True
-- CHECK: notMemberTrueInFalses: True
-- CHECK: notMemberFalseInFalses: False
-- CHECK: notMemberTrueInTrues: False
-- CHECK: notMemberTrueEmpty: True
-- CHECK: notMemberFalseEmpty: True

import Html exposing (text)


main =
    let
        _ = Debug.log "notMemberFalseInTrues" (not (List.member False [ True, True, True ]))
        _ = Debug.log "notMemberTrueInFalses" (not (List.member True [ False, False, False ]))
        _ = Debug.log "notMemberFalseInFalses" (not (List.member False [ False, False ]))
        _ = Debug.log "notMemberTrueInTrues" (not (List.member True [ True, True ]))
        _ = Debug.log "notMemberTrueEmpty" (not (List.member True []))
        _ = Debug.log "notMemberFalseEmpty" (not (List.member False []))
    in
    text "done"
