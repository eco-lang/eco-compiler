module EqualityBoolListMemberTest exposing (main)

{-| `List.member` finds `Bool` values in a list correctly.

`List.member` compares with `==`. The test looks for `True` and for `False` in
an all-`True` list, an all-`False` list and a mixed list, and for `True` in an
empty list, which is `False`.

-}

-- CHECK: memberTrueOfTrues: True
-- CHECK: memberFalseOfTrues: False
-- CHECK: memberFalseOfFalses: True
-- CHECK: memberTrueOfFalses: False
-- CHECK: memberTrueMixed: True
-- CHECK: memberFalseMixed: True
-- CHECK: memberTrueEmpty: False

import Html exposing (text)


main =
    let
        allTrue : List Bool
        allTrue = [ True, True, True ]

        allFalse : List Bool
        allFalse = [ False, False, False ]

        mixed : List Bool
        mixed = [ True, False, True, False ]

        empty : List Bool
        empty = []

        _ = Debug.log "memberTrueOfTrues" (List.member True allTrue)
        _ = Debug.log "memberFalseOfTrues" (List.member False allTrue)
        _ = Debug.log "memberFalseOfFalses" (List.member False allFalse)
        _ = Debug.log "memberTrueOfFalses" (List.member True allFalse)
        _ = Debug.log "memberTrueMixed" (List.member True mixed)
        _ = Debug.log "memberFalseMixed" (List.member False mixed)
        _ = Debug.log "memberTrueEmpty" (List.member True empty)
    in
    text "done"
