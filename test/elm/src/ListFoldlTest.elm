module ListFoldlTest exposing (main)

{-| Test List.foldl.
-}

-- CHECK: sum: 10
-- CHECK: product: 24
-- CHECK: concat: "abc"

import Html exposing (text)


main =
    let
        _ = Debug.log "sum" (List.foldl (+) 0 [1, 2, 3, 4])
        _ = Debug.log "product" (List.foldl (*) 1 [1, 2, 3, 4])
        _ = Debug.log "concat" (List.foldl (++) "" ["a", "b", "c"])
    in
    text "done"
