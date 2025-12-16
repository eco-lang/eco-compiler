module TailRecursiveSumTest exposing (main)

{-| Test tail recursion.
-}

-- CHECK: sum1: 15
-- CHECK: sum2: 55
-- CHECK: sum3: 5050

import Html exposing (text)


sumHelper n acc =
    if n <= 0 then
        acc
    else
        sumHelper (n - 1) (acc + n)


sumTo n = sumHelper n 0


main =
    let
        _ = Debug.log "sum1" (sumTo 5)
        _ = Debug.log "sum2" (sumTo 10)
        _ = Debug.log "sum3" (sumTo 100)
    in
    text "done"
