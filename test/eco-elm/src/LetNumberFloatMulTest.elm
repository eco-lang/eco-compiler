module LetNumberFloatMulTest exposing (main)

{-| An unannotated let-bound `number` used as an operand of `Float`
multiplication is a `Float`, just as the same literal written inline would be.

  - `computeA` is `1.4 * n` with `n = 30`, which rounds to 42.
  - `computeB` binds both operands in the same `let`, `fontSize = 30` and
    `lineHeightRatio = 1.4`, and multiplies them: 42.
  - `computeC` binds `z = 10 + 20`, an expression rather than a literal, and
    computes `z * 1.5`: 45.

## eco

Regression test for a monomorphization bug. The let-bound `number` was
specialized to `Int` while `(*)` was specialized to `Float`, so `n` was
lowered to an `i64` constant and MLIR codegen registered
`Elm_Kernel_Basics_mul_Float` with two ABIs, failing with `Kernel signature
mismatch for Elm_Kernel_Basics_mul_Float: existing (f64, f64 -> f64) vs new
(f64, i64 -> f64)`. An inline literal unified correctly; only the let-bound
`number` defaulted to `Int`. `computeC` shows the bug is not specific to
literals.

-}

-- CHECK: a: 42
-- CHECK: b: 42
-- CHECK: c: 45

import Html exposing (text)


computeA : Float
computeA =
    let
        n =
            30
    in
    1.4 * n


computeB : Float
computeB =
    let
        fontSize =
            30

        lineHeightRatio =
            1.4
    in
    lineHeightRatio * fontSize


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
