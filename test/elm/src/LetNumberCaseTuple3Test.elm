module LetNumberCaseTuple3Test exposing (main)

{-| 3-tuple destructured via `case`, summing the slots two ways. `a + b + c`
demands all three `number` slots at `Int` (the eager default); `a + b + c + 1.0`
demands them at `Float`. Each `case` binds its own `( a, b, c )`, so the two
sums independently exercise the Int-default and the Float-demand specialization
of an independent-var 3-slot tuple destructure — the hardest filler-slot shape
for the let-bound-`number`-via-destructure fix (see `LetNumberDestructureTest`).

If a slot's Float demand fails to flow back to the destructure, the projected
`i64` reaches `eco.float.mul` and the program crashes (verify) or registers a
conflicting `mul_Float` signature (emit); the Int sum guards against the inverse
(a spurious Float widening of an all-Int destructure).

Int sum:   10 + 20 + 30        = 60
Float sum: 10 + 20 + 30 + 1.0  = 61.0  (round -> 61)

-}

-- CHECK: case-tuple3-int: 60
-- CHECK: case-tuple3-float: 61

import Html exposing (text)


main =
    let
        intSum =
            case ( 10, 20, 30 ) of
                ( a, b, c ) ->
                    a + b + c

        floatSum =
            case ( 10, 20, 30 ) of
                ( a, b, c ) ->
                    a + b + c + 1.0

        _ =
            Debug.log "case-tuple3-int" intSum

        _ =
            Debug.log "case-tuple3-float" (round floatSum)
    in
    text "done"
