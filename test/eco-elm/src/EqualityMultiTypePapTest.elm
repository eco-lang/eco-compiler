module EqualityMultiTypePapTest exposing (main)

{-| `(==)` bound to two local names and partially applied at `Int` and at `String` filters two lists, in the same module as a `case` on a string literal.

`List.filter (eqInt 3)` keeps the two 3s, `List.filter (eqStr "b")` keeps the two `"b"`s, and `classify "foo"` takes the `"foo"` branch.

## eco

`==` used as a function value at `Int`, `String` and `Char` in one module must not give `Elm_Kernel_Utils_equal` conflicting signatures: every use goes through the all-boxed ABI (CGEN_038 in design_docs/invariants.csv; compiler/src/Compiler/GenerateMlir/KernelAbi.elm).

-}

-- CHECK: intFiltered: [3,3]
-- CHECK: strFiltered: ["b","b"]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        _ ->
            "other"


main =
    let
        eqInt = (==)
        eqStr = (==)
        intFiltered = List.filter (eqInt 3) [1, 2, 3, 4, 3]
        strFiltered = List.filter (eqStr "b") ["a", "b", "c", "b"]
        _ = Debug.log "intFiltered" intFiltered
        _ = Debug.log "strFiltered" strFiltered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
