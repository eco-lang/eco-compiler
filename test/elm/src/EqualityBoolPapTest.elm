module EqualityBoolPapTest exposing (main)

{-| First-class reference to `(==)` partially applied to a Bool. The
intrinsic path cannot fire on a value-position `(==)`, so this *must*
land on a kernel symbol. Today that symbol is the unsuffixed
`Elm_Kernel_Utils_equal` (no `_Bool` variant), exposing the bug.
-}

-- CHECK: isTrueList: [True,False,True,False]
-- CHECK: isFalseList: [False,True,False,True]
-- CHECK: filterTrue: [True,True]
-- CHECK: filterFalse: [False,False]
-- CHECK: anyTrue: True
-- CHECK: anyFalse: True

import Html exposing (text)


main =
    let
        isTrue : Bool -> Bool
        isTrue = (==) True

        isFalse : Bool -> Bool
        isFalse = (==) False

        bs : List Bool
        bs = [ True, False, True, False ]

        _ = Debug.log "isTrueList" (List.map isTrue bs)
        _ = Debug.log "isFalseList" (List.map isFalse bs)
        _ = Debug.log "filterTrue" (List.filter isTrue bs)
        _ = Debug.log "filterFalse" (List.filter isFalse bs)
        _ = Debug.log "anyTrue" (List.any isTrue bs)
        _ = Debug.log "anyFalse" (List.any isFalse bs)
    in
    text "done"
