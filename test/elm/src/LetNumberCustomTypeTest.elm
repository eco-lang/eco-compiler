module LetNumberCustomTypeTest exposing (main)

{-| Probe for the let-bound-`number` mis-specialization (see
`LetNumberFloatMulTest`) routed through a custom union type payload.

`v = NumBox 30` binds a `number` inside a constructor; the `case` extracts it
and uses it at `Float`. If the binding defaults to `Int`, the payload is a boxed
`i64` reinterpreted as `f64` (silent miscompile) — correct answer is 45.

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
