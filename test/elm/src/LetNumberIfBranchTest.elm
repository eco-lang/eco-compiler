module LetNumberIfBranchTest exposing (main)

{-| Probe: a `number` routed through an `if` expression before the `Float` use.
Both branches are `number`; the `* 1.5` forces the whole expression to `Float`.
Correct: 1.5*30 = 45.

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
