module ListAnyBoolTest exposing (main)

{-| `List.any` and `List.all` on `List Bool`, with `identity` and `not` as the
predicate, return the expected `True` or `False`.
-}

-- CHECK: any_id_true: True
-- CHECK: any_id_false: False
-- CHECK: any_not_true: True
-- CHECK: any_not_false: False
-- CHECK: all_id_true: True
-- CHECK: all_id_false: False

import Html exposing (text)


main =
    let
        _ = Debug.log "any_id_true" (List.any identity [False, True, False])
        _ = Debug.log "any_id_false" (List.any identity [False, False, False])
        _ = Debug.log "any_not_true" (List.any not [True, False])
        _ = Debug.log "any_not_false" (List.any not [True, True])
        _ = Debug.log "all_id_true" (List.all identity [True, True, True])
        _ = Debug.log "all_id_false" (List.all identity [True, False, True])
    in
    text "done"
