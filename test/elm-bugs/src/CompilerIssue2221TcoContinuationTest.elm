module CompilerIssue2221TcoContinuationTest exposing (main)

{-| A tail-recursive function in continuation-passing style loops forever / overflows the stack.

<https://github.com/elm/compiler/issues/2221>

`g` builds a continuation `\result -> cont (result * value)` and calls itself in tail position.
TCO turns the call into a loop that reassigns `cont` and `value`, so the new continuation calls
itself instead of the previous one. Elm 0.19.1 throws `RangeError: Maximum call stack size
exceeded` for `g 2`; the correct result of `g 5 identity` is 120 (5 factorial).

-}

-- CHECK: g 5: 120

import Html exposing (text)


g : Int -> (Int -> a) -> a
g value cont =
    case value of
        1 ->
            cont 1

        _ ->
            g (value - 1) (\result -> cont (result * value))


main =
    let
        _ =
            Debug.log "g 5" (g 5 identity)
    in
    text "done"
