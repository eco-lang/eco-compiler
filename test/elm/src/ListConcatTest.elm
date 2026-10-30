module ListConcatTest exposing (main)

{-| Test List.concat and ++.
-}

-- CHECK: append: [1,2,3,4]
-- CHECK: concat: [1,2,3,4,5,6]
-- CHECK: empty: [1,2,3]

import Html exposing (text)


main =
    let
        _ = Debug.log "append" ([1, 2] ++ [3, 4])
        _ = Debug.log "concat" (List.concat [[1, 2], [3, 4], [5, 6]])
        _ = Debug.log "empty" ([] ++ [1, 2, 3])
    in
    text "done"
