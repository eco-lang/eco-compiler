module EqualityBoolListMemberTest exposing (main)

{-| `List.member` uses polymorphic `(==)` internally. For `Bool` elements
there is no `Elm_Kernel_Utils_equal_Bool` suffix (no Phase-C variant),
so this routes through the unsuffixed kernel.

Mirrors `EqualityIntPapTest` but on the Bool axis.
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
