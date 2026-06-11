module InlineDupLetNamesTest exposing (main)

{-| Inlining the same helper twice, with one call nested in the other's
argument, copies the helper's internal let-bound names (the case-scrutinee
tuple binding) twice onto one let chain. MonoInlineSimplify must
alpha-rename the instantiated body's let names, or MLIR codegen forces both
scrutinee tuples onto the same SSA placeholder ("redefinition of SSA
value" / "operand does not dominate this use").
-}

-- CHECK: InlineDupLetNamesTest: 6

import Html exposing (text)


helper : Int -> Int -> Int
helper a b =
    case ( a, b ) of
        ( 0, 0 ) ->
            1

        ( x, y ) ->
            x + y


main =
    let
        _ =
            Debug.log "InlineDupLetNamesTest" (helper (helper 1 2) 3)
    in
    text "ok"
