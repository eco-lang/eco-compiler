module CoreIssue1080ClampNanTest exposing (main)

{-| `clamp -100 100` of NaN returns NaN.

<https://github.com/elm/core/issues/1080>

`clamp` is documented as returning `low` when the number is below it, `high` when above it, and
the number otherwise. Both comparisons are false for NaN, so the result must be NaN. Elm 0.19.1
returns 100.

-}

-- CHECK: clamp nan: NaN

import Html exposing (text)


main =
    let
        _ =
            Debug.log "clamp nan" (clamp -100 100 (0 / 0))
    in
    text "done"
