module NotEqualBoolPapTest exposing (main)

{-| First-class reference to `(/=)` partially applied to a Bool. The
intrinsic path cannot fire on a value-position `(/=)`, so this must
land on `Elm_Kernel_Utils_notEqual` — the path under audit.
-}

-- CHECK: isNotTrueList: [False, True, False, True]
-- CHECK: isNotFalseList: [True, False, True, False]
-- CHECK: filterNotTrue: [False, False]
-- CHECK: filterNotFalse: [True, True]
-- CHECK: anyNotTrue: True
-- CHECK: anyNotFalse: True

import Html exposing (text)


main =
    let
        isNotTrue : Bool -> Bool
        isNotTrue = (/=) True

        isNotFalse : Bool -> Bool
        isNotFalse = (/=) False

        bs : List Bool
        bs = [ True, False, True, False ]

        _ = Debug.log "isNotTrueList" (List.map isNotTrue bs)
        _ = Debug.log "isNotFalseList" (List.map isNotFalse bs)
        _ = Debug.log "filterNotTrue" (List.filter isNotTrue bs)
        _ = Debug.log "filterNotFalse" (List.filter isNotFalse bs)
        _ = Debug.log "anyNotTrue" (List.any isNotTrue bs)
        _ = Debug.log "anyNotFalse" (List.any isNotFalse bs)
    in
    text "done"
