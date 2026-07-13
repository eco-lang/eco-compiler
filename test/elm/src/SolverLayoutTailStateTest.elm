module SolverLayoutTailStateTest exposing (main)

{-| Solver layout probe for the TailCall connection gap: the solver's
TailCall arm translates recursive-call args WITHOUT unifying them against
the loop params (Translate.elm TailCall arm has no connectTypes), and the
loop params are classified/recorded BEFORE the body translates. The local
tail loop threads a `( a, Int )` tuple; the generic slot is demanded at
Int (raw i64 when concrete) and the destructured `x` is used only
opaquely (repacked) — an erased-erased candidate on both the path node
and the leaf.
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
