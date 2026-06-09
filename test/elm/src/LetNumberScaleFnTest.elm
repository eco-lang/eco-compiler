module LetNumberScaleFnTest exposing (main)

{-| Probe (§3.4 of the exploration guide): a record of `number`s passed to a
user function whose body buries the `Float` constraint. The constraining `Float`
lives inside `scale`, not at any operator in `main`. Correct: 1.5*30 + 1.5*40 =
45 + 60 = 105.

-}

-- CHECK: scale: 105

import Html exposing (text)


scale : Float -> { lo : Float, hi : Float } -> Float
scale factor pair =
    factor * pair.lo + factor * pair.hi


main =
    let
        p =
            { lo = 30, hi = 40 }

        result =
            round (scale 1.5 p)

        _ =
            Debug.log "scale" result
    in
    text "done"
