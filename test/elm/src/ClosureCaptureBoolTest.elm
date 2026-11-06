module ClosureCaptureBoolTest exposing (main)

{-| Partially applying a `Bool -> Int -> Int` function to a `Bool` gives a
function that remembers that `Bool`.

`boolToInt True` and `boolToInt False` are applied to 0 and log 1 and 0.

-}

-- CHECK: when_true: 1
-- CHECK: when_false: 0

import Html exposing (text)


boolToInt : Bool -> Int -> Int
boolToInt flag dummy =
    if flag then
        1
    else
        0


main =
    let
        trueF =
            boolToInt True

        falseF =
            boolToInt False

        _ = Debug.log "when_true" (trueF 0)
        _ = Debug.log "when_false" (falseF 0)
    in
    text "done"
