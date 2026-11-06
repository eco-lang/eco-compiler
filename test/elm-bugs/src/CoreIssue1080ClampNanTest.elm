module CoreIssue1080ClampNanTest exposing (main)

{-| `clamp` returns the upper bound for NaN instead of passing NaN through.

<https://github.com/elm/core/issues/1080>

Elm 0.19.1 gives `clamp -100 100 (0/0) == 100`. `clamp` is defined as "if number < low then low
else if number > high then high else number"; both comparisons are false for NaN, so the result
must be NaN.

-}

-- CHECK: clamp nan: NaN

import Html exposing (text)


main =
    let
        _ =
            Debug.log "clamp nan" (clamp -100 100 (0 / 0))
    in
    text "done"
