module ArrayAppendRepeatedTest exposing (main)

{-| Growing an `Array` by 100 successive `Array.append` calls, three elements at a time, keeps
every element in order.

Step `count` appends `[ count, count + 1, count + 2 ]`, counting down from 100, so the result
has 300 elements, starts with 100 and ends with 3 (from the final step's `[ 1, 2, 3 ]`).

-}

-- CHECK: finalLength: 300
-- CHECK: firstElem: Just 100
-- CHECK: lastElem: Just 3

import Array exposing (Array)
import Html exposing (text)


loop : Int -> Array Int -> Array Int
loop count acc =
    if count <= 0 then
        acc

    else
        loop (count - 1) (Array.append acc (Array.fromList [ count, count + 1, count + 2 ]))


main =
    let
        result =
            loop 100 Array.empty

        _ = Debug.log "finalLength" (Array.length result)
        _ = Debug.log "firstElem"   (Array.get 0 result)
        _ = Debug.log "lastElem"    (Array.get (Array.length result - 1) result)
    in
    text "done"
