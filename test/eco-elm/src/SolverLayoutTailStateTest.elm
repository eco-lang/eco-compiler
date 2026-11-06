module SolverLayoutTailStateTest exposing (main)

{-| A local tail-recursive loop inside a polymorphic function threads a tuple `( a, Int )`, keeping the generic element unchanged while counting.

`run seed n` defines a local `go` that destructures the pair, rebuilds it with
the same first element and the count increased by one, and repeats `n` times.
`run 9 5` gives `( 9, 5 )`, printed as `v * 100 + c`, which is 905.

## eco

A solver layout probe for the tail-call connection gap: the solver's TailCall
arm in compiler/src/Compiler/Monomorphize/Solver/Translate.elm translated the
recursive-call arguments without unifying them against the loop parameters, and
the parameters are classified before the body is translated. The local loop
threads an `( a, Int )` tuple whose generic slot is demanded at `Int` (a raw
`i64` when concrete) while the destructured `x` is used only opaquely, so both
the path node and the leaf could be recorded erased
(plans/solver-layout-connectivity-reconciliation.md).

-}

-- CHECK: SolverLayoutTailState: 905

import Html exposing (text)


run : a -> Int -> ( a, Int )
run seed n =
    let
        go pair i =
            if i <= 0 then
                pair

            else
                let
                    ( x, cnt ) =
                        pair
                in
                go ( x, cnt + 1 ) (i - 1)
    in
    go ( seed, 0 ) n


main =
    let
        ( v, c ) =
            run 9 5

        _ =
            Debug.log "SolverLayoutTailState" (v * 100 + c)
    in
    text "done"
