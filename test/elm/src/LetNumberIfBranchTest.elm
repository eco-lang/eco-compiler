module LetNumberIfBranchTest exposing (main)

{-| A let-bound `number` passed through an `if` expression whose result is
multiplied by a `Float` is a `Float`.

With `n = 30`, `(if n > 0 then n else 0) * 1.5` takes the `then` branch and
rounds to 45.

-}

-- CHECK: ifbr: 45

import Html exposing (text)


main =
    let
        n =
            30

        result =
            round
                ((if n > 0 then
                    n

                  else
                    0
                 )
                    * 1.5
                )

        _ =
            Debug.log "ifbr" result
    in
    text "done"
