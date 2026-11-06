module CoreIssue1115NanEqualsLiteralZeroTest exposing (main)

{-| `x == 0` with a literal 0 is True when x is NaN.

<https://github.com/elm/core/issues/1115>

Elm 0.19.1 compiles a comparison with the literal `0` to `!x`, which is true for NaN. NaN is not
equal to anything, so all these comparisons must be False (as `nan == zero` already is).

-}

-- CHECK: nan == 0: False
-- CHECK: 0 == nan: False
-- CHECK: nan == zero: False

import Html exposing (text)


main =
    let
        zero =
            0

        nan =
            0 / 0

        _ =
            Debug.log "nan == 0" (nan == 0)

        _ =
            Debug.log "0 == nan" (0 == nan)

        _ =
            Debug.log "nan == zero" (nan == zero)
    in
    text "done"
