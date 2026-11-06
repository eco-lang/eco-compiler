module NotEqualBoolListMemberTest exposing (main)

{-| `not (List.member x xs)` gives the right answer for `Bool` values, which
relies on `List.member` comparing `Bool`s with `==` correctly.

The tests look for `False` among `True`s, `True` among `False`s, each value
in a list of only that value, and each value in an empty list.
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
