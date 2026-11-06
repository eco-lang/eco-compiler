module BoolShortCircuitTest exposing (main)

{-| `&&` and `||` short-circuit: `False && x` and `True || x` never evaluate `x`.

The right operand calls a function that recurses without end, so the program
only prints its two lines if that operand is skipped.
-}

-- CHECK: shortAnd: False
-- CHECK: shortOr: True

import Html exposing (text)


{-| Recurses without end; never called when the program is correct.
-}
stackBomb : Int -> Int
stackBomb n =
    1 + stackBomb (n + 1)


{-| A Bool operand that calls `stackBomb`, so evaluating it never returns.
-}
shouldNotRun : () -> Bool
shouldNotRun _ =
    stackBomb 0 > 0


main =
    let
        -- False && _ must skip the RHS entirely
        _ =
            Debug.log "shortAnd" (False && shouldNotRun ())

        -- True || _ must skip the RHS entirely
        _ =
            Debug.log "shortOr" (True || shouldNotRun ())
    in
    text "done"
