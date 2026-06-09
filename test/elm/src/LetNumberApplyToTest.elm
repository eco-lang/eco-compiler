module LetNumberApplyToTest exposing (main)

{-| Probe: the `Float` constraint is two hops away, inside a lambda passed to a
generic higher-order combinator `applyTo`. The binding `n` reaches the Float
multiply only after going through `applyTo (\x -> x * 1.5)`. Correct: 45.

-}

-- CHECK: applyTo: 45

import Html exposing (text)


applyTo : (a -> b) -> a -> b
applyTo f x =
    f x


main =
    let
        n =
            30

        result =
            round (applyTo (\x -> x * 1.5) n)

        _ =
            Debug.log "applyTo" result
    in
    text "done"
