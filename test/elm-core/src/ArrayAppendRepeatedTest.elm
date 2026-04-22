module ArrayAppendRepeatedTest exposing (main)

{-| Repeatedly growing an `Array` via `Array.append` must not crash
    and must preserve the element count. Scaled-down regression for a
    SIGSEGV observed in the stress suite (ArrayConcatMap).
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
