module CoreIssue1115NanEqualsLiteralZeroTest exposing (main)

{-| NaN compared with a literal `0` is not equal, on either side of `==`.

<https://github.com/elm/core/issues/1115>

Elm 0.19.1 compiles a comparison with the literal `0` to a JavaScript truthiness test, which is
true for NaN. The test also compares NaN with a `zero` variable, which Elm 0.19.1 already gets
right.

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
