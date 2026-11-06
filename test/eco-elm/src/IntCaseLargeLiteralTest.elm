module IntCaseLargeLiteralTest exposing (main)

{-| A `case` on an Int with a pattern at or above 2^32 matches only that exact value, not a value that agrees with it in the low 32 bits.

`classify` has the patterns `5000000000` and `7`. The scrutinee 705032704 is
5000000000 - 2^32, so it agrees with 5000000000 in its low 32 bits; it must fall
through to the wildcard and give `"other"`.

## eco

An Int pattern at or above 2^32 is stored in the `eco.case` `tags` dense i64
array. Two fixed bugs made 705032704 take the 5000000000 branch:

compiler/src/Mlir/Bytecode/AttrType.elm wrote each dense-array element as its
low 32 bits followed by zero bytes (unit test:
compiler/tests/Mlir/Bytecode/AttrTypeTest.elm).

runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp lowered every int
`eco.case` with non-negative tags to `scf.index_switch`, whose upstream
lowering switches on i32 and drops the high bits. It now uses index_switch only
for tags in [0, 2^31-1] with the scrutinee clamped, and an i64 compare chain
otherwise (CGEN_048 in design_docs/invariants.csv; codegen test
test/codegen/case_int_large_tags_jit.mlir).

-}

-- CHECK: big: "big"
-- CHECK: low: "other"
-- CHECK: seven: "seven"

import Html exposing (text)


classify : Int -> String
classify n =
    case n of
        5000000000 ->
            "big"

        7 ->
            "seven"

        _ ->
            "other"


main =
    let
        _ =
            Debug.log "big" (classify 5000000000)

        _ =
            Debug.log "low" (classify 705032704)

        _ =
            Debug.log "seven" (classify 7)
    in
    text "done"
