module CaseOrderTest exposing (main)

{-| Test case expression on Order type (LT, EQ, GT).
-}

-- CHECK: ord1: "less"
-- CHECK: ord2: "equal"
-- CHECK: ord3: "greater"

import Html exposing (text)


orderToStr ord =
    case ord of
        LT -> "less"
        EQ -> "equal"
        GT -> "greater"


main =
    let
        _ = Debug.log "ord1" (orderToStr (compare 1 2))
        _ = Debug.log "ord2" (orderToStr (compare 5 5))
        _ = Debug.log "ord3" (orderToStr (compare 10 3))
    in
    text "done"
