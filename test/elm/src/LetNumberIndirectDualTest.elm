module LetNumberIndirectDualTest exposing (main)

{-| A let-bound `number` used once in a `Float` multiplication and once in an
unconstrained addition takes a type at each use independently.

With `n = 30`, the pair `( n + 1, round (1.5 * n) )` logs `(31,45)`. The
`1.5 * n` use makes that `n` a `Float`; nothing constrains `n + 1` to `Float`.

-}

-- CHECK: dual: (31,45)

import Html exposing (text)


main =
    let
        dual =
            let
                n =
                    30
            in
            ( n + 1, round (1.5 * n) )

        _ =
            Debug.log "dual" dual
    in
    text "done"
