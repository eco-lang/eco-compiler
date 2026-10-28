module IntCaseLargeLiteralTest exposing (main)

{-| An Int `case` pattern at or above 2^32 is stored in the eco.case `tags`
dense i64 array, and `Mlir.Bytecode.AttrType` writes each dense-array element
as its low 32 bits followed by zero bytes. In the bytecode the tag 5000000000
becomes 705032704 (5000000000 - 2^32), so the scrutinee 705032704 wrongly
takes the 5000000000 branch (`ecoc --emit=mlir` on the bytecode shows
`case ... [705032704, 7, 0]`).

A SECOND, independent bug gives the same wrong output even from --text-mlir:
EcoControlFlowToSCF lowers an int eco.case to scf.index_switch, whose upstream
lowering switches on an i32 (`llvm.switch %x : i32 [705032704: ...]`), so the
high 32 bits of tag and scrutinee are dropped. Both must be fixed for this
test to pass.
Also covered by the unit test compiler/tests/Mlir/Bytecode/AttrTypeTest.elm
("dense i64 element 2^32 is written with its high bytes").

EXPECTED TO FAIL until fixed.
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
