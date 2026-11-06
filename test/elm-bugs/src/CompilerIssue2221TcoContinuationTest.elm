module CompilerIssue2221TcoContinuationTest exposing (main)

{-| A tail-recursive function that builds a continuation on each call computes `g 5 identity` as 120.

<https://github.com/elm/compiler/issues/2221>

`g` multiplies the numbers from `value` down to 1 by wrapping `cont` in a new continuation,
`\result -> cont (result * value)`, and calling itself in tail position. Each new continuation
must call the one it wraps. Elm 0.19.1 turns the tail call into a loop that reassigns `cont` and
`value`, so a continuation ends up calling itself, and `g 2` already overflows the stack.

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
