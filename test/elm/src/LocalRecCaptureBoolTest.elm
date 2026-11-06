module LocalRecCaptureBoolTest exposing (main)

{-| A let-bound recursive function reads a Bool defined earlier in the same
`let`, and the loop takes the step size that Bool selects.

`count a` sets `flag = a < 2` and loops from 0 until `i >= 3`, stepping by 1
when `flag` is True and by 2 otherwise. Both values of the flag are covered:

  - `count 1`: flag True, i = 0, 1, 2, 3, result 3
  - `count 5`: flag False, i = 0, 2, 4, result 4
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
