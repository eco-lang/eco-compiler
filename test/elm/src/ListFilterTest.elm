module ListFilterTest exposing (main)

{-| Test List.filter.
-}

-- CHECK: even: [2, 4]
-- CHECK: positive: [1, 2, 3]
-- CHECK: empty: []
-- CHECK: eq_ho: [3, 3]
-- CHECK: eq_ho_string: ["hello", "hello"]

import Html exposing (text)


isEven x = modBy 2 x == 0
isPositive x = x > 0


main =
    let
        _ = Debug.log "even" (List.filter isEven [1, 2, 3, 4, 5])
        _ = Debug.log "positive" (List.filter isPositive [-1, 0, 1, 2, 3])
        _ = Debug.log "empty" (List.filter isEven [])
        _ = Debug.log "eq_ho" (List.filter ((==) 3) [1, 2, 3, 4, 3])
        _ = Debug.log "eq_ho_string" (List.filter ((==) "hello") ["hello", "world", "hello"])
    in
    text "done"
