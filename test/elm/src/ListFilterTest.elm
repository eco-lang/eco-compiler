module ListFilterTest exposing (main)

{-| Test List.filter.
-}

-- CHECK: even: [2,4]
-- CHECK: positive: [1,2,3]
-- CHECK: empty: []

import Html exposing (text)


isEven x = modBy 2 x == 0
isPositive x = x > 0


main =
    let
        _ = Debug.log "even" (List.filter isEven [1, 2, 3, 4, 5])
        _ = Debug.log "positive" (List.filter isPositive [-1, 0, 1, 2, 3])
        _ = Debug.log "empty" (List.filter isEven [])
    in
    text "done"
