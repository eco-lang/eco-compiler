module ListFoldrTest exposing (main)

{-| `List.foldr` folds from the right, shown by a sum and by `(++)` on strings,
where `"abc"` reveals the order.
-}

-- CHECK: sum: 10
-- CHECK: concat: "abc"

import Html exposing (text)


main =
    let
        _ = Debug.log "sum" (List.foldr (+) 0 [1, 2, 3, 4])
        _ = Debug.log "concat" (List.foldr (++) "" ["a", "b", "c"])
    in
    text "done"
