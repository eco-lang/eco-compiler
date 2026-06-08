module LetNumberFloatMulTest exposing (main)

{-| Regression test for a monomorphization bug in the native (AOT) backend.

A let-bound, unannotated numeric literal (`n = 30`, type `number`) used as
an operand of a `Float` multiplication was monomorphized to `Int` rather than
`Float`. The `(*)` operator instance was specialized to `Float -> Float ->
Float` (so the kernel symbol is `Elm_Kernel_Basics_mul_Float`), but the `n`
operand kept type `Int` and was lowered to an `i64` constant. MLIR codegen
then registered `mul_Float` twice with conflicting ABIs — once as
`(f64, f64) -> f64` and once as `(f64, i64) -> f64` — crashing with:

    Kernel signature mismatch for Elm_Kernel_Basics_mul_Float:
        existing (f64, f64 -> f64) vs new (f64, i64 -> f64)

The mistype is in monomorphization: `n` should be specialized to `Float`
because `1.4 * n` forces it. An inline literal (`1.4 * 30`) unifies correctly;
only the let-bound `number` defaults to `Int`.

-}

-- CHECK: a: 42
-- CHECK: b: 42
-- CHECK: c: 45

import Html exposing (text)


-- Minimal trigger: let-bound `number` literal in a Float multiply.
computeA : Float
computeA =
    let
        n =
            30
    in
    1.4 * n


-- The original elm-oo-style shape: the same `number` binding is also used in
-- a plain (Int-defaulting) position, forcing the dual specialization.
computeB : Float
computeB =
    let
        fontSize =
            30

        lineHeightRatio =
            1.4
    in
    lineHeightRatio * fontSize


-- Not literal-specific: a `number` binding whose RHS is an expression
-- (`10 + 20`), used in a Float multiply, defaults to `Int` the same way.
computeC : Float
computeC =
    let
        z =
            10 + 20
    in
    z * 1.5


main =
    let
        _ =
            Debug.log "a" (round computeA)

        _ =
            Debug.log "b" (round computeB)

        _ =
            Debug.log "c" (round computeC)
    in
    text "done"
