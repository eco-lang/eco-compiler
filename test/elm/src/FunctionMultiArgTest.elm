module FunctionMultiArgTest exposing (main)

{-| Unannotated top-level functions of three, four and five arguments return the sum of their arguments.

The test logs `addThree 1 2 3` (6), `addFour 1 2 3 4` (10) and
`addFive 1 2 3 4 5` (15).

-}

-- CHECK: three: 6
-- CHECK: four: 10
-- CHECK: five: 15

import Html exposing (text)


addThree a b c = a + b + c
addFour a b c d = a + b + c + d
addFive a b c d e = a + b + c + d + e


main =
    let
        _ = Debug.log "three" (addThree 1 2 3)
        _ = Debug.log "four" (addFour 1 2 3 4)
        _ = Debug.log "five" (addFive 1 2 3 4 5)
    in
    text "done"
