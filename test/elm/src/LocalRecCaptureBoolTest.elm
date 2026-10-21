module LocalRecCaptureBoolTest exposing (main)

{-| A let-bound local RECURSIVE function captures a Bool computed in the same
`let`. Previously rejected while lowering:

    'eco.papCreate' op captured Bool (i1) at index 0 violates REP_CLOSURE_001

Bool must be boxed to !eco.value at the closure boundary (REP_CLOSURE_001,
FORBID_CLOSURE_001). Covers both branches of the captured flag.

count 1: flag True  -> 0,1,2,3 -> 3
count 5: flag False -> 0,2,4   -> 4

-}

-- CHECK: count_true: 3
-- CHECK: count_false: 4

import Html exposing (text)


count : Int -> Int
count a =
    let
        flag =
            a < 2

        loop i =
            if i >= 3 then
                i

            else if flag then
                loop (i + 1)

            else
                loop (i + 2)
    in
    loop 0


main =
    let
        _ =
            Debug.log "count_true" (count 1)

        _ =
            Debug.log "count_false" (count 5)
    in
    text "done"
