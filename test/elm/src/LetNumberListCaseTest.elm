module LetNumberListCaseTest exposing (main)

{-| A let-bound `number` value destructured out of a let-bound number list by a
`case`, then used both at `Int` and at `Float`:
`xs = [ 1, 2, 3 ]`, `prod = case xs of a :: b :: _ -> a * b`, then
`prod + 0` as an `Int` and `round (prod * 1.5)`, a `Float`. This is valid Elm (both
are let-polymorphic in `number`).

The native build used to give the Float use's `prod` the Int specialization's
`i64`: `eco make --output=x.mlir` failed with "Kernel signature mismatch for
Elm_Kernel_Basics_mul_Float", and the E2E harness's MLIR failed verification
(`eco.float.mul` given an `i64`). The uses of a let-bound number shared one
type variable, and the list's tail was read from the `Int` instance
(plans/dead-code-report.md, side finding; see also `LetNumberDualUseTest`).

Int use:   1 * 2 + 0   = 2
Float use: 1 * 2 * 1.5 = 3.0  (round -> 3)

-}

-- CHECK: list-case-int: 2
-- CHECK: list-case-float: 3

import Html exposing (text)


main =
    let
        xs =
            [ 1, 2, 3 ]

        prod =
            case xs of
                a :: b :: _ ->
                    a * b

                _ ->
                    0

        _ =
            Debug.log "list-case-int" (prod + 0)

        _ =
            Debug.log "list-case-float" (round (prod * 1.5))
    in
    text "done"
