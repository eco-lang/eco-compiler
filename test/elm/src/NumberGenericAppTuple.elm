module NumberGenericAppTuple exposing (main)

{-| Regression test for the number-multi gate relaxation
(plans/fix-number-constraint-lost-solver-root-reuse.md §7, Mechanism B).

A scalar `number` literal flows through a generic application — here
`Tuple.first : ( a, b ) -> a` — so the `let`-binding's RHS is a generic-function
*call*, not direct numeric data. The number-multi gate (`isNumericDataRhs`)
rejected such an RHS, so the `number` defaulted to `Int` and miscompiled to `i64`
when used in the `Float` multiply `1.5 * n` (`mul_Float (f64, i64)` mismatch). The
binding's `CNumber` constraint is intact (`hasNum=True`) — this is the gate
mechanism, distinct from the solver-root constraint loss. Correct: 45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


main =
    let
        n =
            Tuple.first ( 30, "x" )

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
