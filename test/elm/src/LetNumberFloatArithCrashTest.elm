module LetNumberFloatArithCrashTest exposing (main)

{-| Regression test (native/AOT backend): a let-bound, unannotated `number`
literal used as an operand of a Float kernel is monomorphized to `Int` (lowered
to an `i64` constant) while the operator instance is specialized to `Float`.
MLIR codegen registers the Float kernel symbol with two conflicting ABIs and
crashes (`Kernel signature mismatch …`).

This is the same root cause as `LetNumberFloatMulTest`, generalized across the
Float arithmetic kernels: `sqrt`, `(+)`, `(/)`, `(^)`. Each `let n = …` is a
bare `number` binding; an inline literal (`sqrt 144`) would unify correctly —
only the let-bound `number` defaults to `Int`.

Compiles+runs only once the monomorphizer specializes the binding to the
numeric type its use site demands.

-}

-- CHECK: sqrt: 12
-- CHECK: add: 31
-- CHECK: div: 6
-- CHECK: pow: 8

import Html exposing (text)


sqrtN : Float
sqrtN =
    let
        n =
            144
    in
    sqrt n


addN : Float
addN =
    let
        n =
            30
    in
    n + 1.4


divN : Float
divN =
    let
        n =
            30
    in
    n / 5.0


powN : Float
powN =
    let
        n =
            2
    in
    n ^ 3.0


main =
    let
        _ =
            Debug.log "sqrt" (round sqrtN)

        _ =
            Debug.log "add" (round addN)

        _ =
            Debug.log "div" (round divN)

        _ =
            Debug.log "pow" (round powN)
    in
    text "done"
