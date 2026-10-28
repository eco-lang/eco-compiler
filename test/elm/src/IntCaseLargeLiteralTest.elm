module IntCaseLargeLiteralTest exposing (main)

{-| An Int `case` pattern at or above 2^32 is stored in the eco.case `tags`
dense i64 array. Two independent bugs, both fixed, made the scrutinee
705032704 (5000000000 - 2^32) take the 5000000000 branch:

`Mlir.Bytecode.AttrType` wrote each dense-array element as its low 32 bits
followed by zero bytes, so in the bytecode the tag 5000000000 became 705032704.

EcoControlFlowToSCF lowered every int eco.case with non-negative tags to
scf.index_switch, whose upstream lowering switches on an i32
(`llvm.switch %x : i32 [705032704: ...]`), dropping the high 32 bits of tag
and scrutinee. It now uses index_switch only for tags in [0, 2^31-1] with the
scrutinee clamped, and an i64 compare chain otherwise (CGEN_048).
Also covered by the unit test compiler/tests/Mlir/Bytecode/AttrTypeTest.elm
("dense i64 element 2^32 is written with its high bytes") and the codegen test
test/codegen/case_int_large_tags_jit.mlir.
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
