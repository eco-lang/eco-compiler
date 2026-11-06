module CoreIssue960PowNegativeExponentIntTest exposing (main)

{-| `(^)` on two `Int`s with a negative exponent returns a fraction typed as `Int`.

<https://github.com/elm/core/issues/960>

Elm 0.19.1 evaluates `(2 : Int) ^ -1` to `0.5`, so `String.fromInt` of an `Int` prints `"0.5"`.
Whatever the result, a value of type `Int` must be a whole number.

-}

-- CHECK: {{pow: "-?[0-9]+"(\n|$)}}

import Html exposing (text)


two : Int
two =
    2


main =
    let
        _ =
            Debug.log "pow" (String.fromInt (two ^ -1))
    in
    text "done"
