module BoolShortCircuitTest exposing (main)

{-| Tests that `&&` and `||` short-circuit, per Elm semantics.

    If the native backend lowers these to a strict bitwise AND / OR (e.g.
    `arith.andi` / `arith.ori`), the right-hand operand is always evaluated and
    the test crashes via `stackBomb`. With correct short-circuit semantics, the
    right-hand operand is never evaluated and both CHECK lines appear.

-}

-- CHECK: shortAnd: False
-- CHECK: shortOr: True

import Html exposing (text)


{-| Non-tail-recursive stack bomb. Each call builds up a pending `1 +` frame on
    the activation stack before the recursive call, so tail-call optimization
    cannot flatten it into a loop. Invoking it is guaranteed to overflow.
-}
stackBomb : Int -> Int
stackBomb n =
    1 + stackBomb (n + 1)


{-| Wraps `stackBomb` as a `Bool`-producing RHS for `&&` / `||`. Used only to
    make the "never evaluate RHS" contract observable: if this function runs,
    the process dies before any CHECK line is printed.
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
