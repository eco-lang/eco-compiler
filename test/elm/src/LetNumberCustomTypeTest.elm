module LetNumberCustomTypeTest exposing (main)

{-| A let-bound custom type value whose type parameter is `number`, built from
an integer literal, has its payload extracted by `case` and multiplied by a
`Float`.

`v = NumBox 30` has type `NumBox number`. The `case` binds the payload to `k`
and computes `round (k * 1.5)`, so `k` is used as a `Float` and the logged
result is 45.

-}

-- CHECK: ctor: 45

import Html exposing (text)


type NumBox number
    = NumBox number


main =
    let
        v =
            NumBox 30

        result =
            case v of
                NumBox k ->
                    round (k * 1.5)

        _ =
            Debug.log "ctor" result
    in
    text "done"
