module EqualityIntPapWithStringChainTest exposing (main)

{-| `(==)` bound to a local name and partially applied to an `Int` filters a list, in the same module as a `case` that matches a `String` against string literals.

`List.filter (eq 5)` over `[1, 2, 5, 3, 5]` keeps the two 5s, and `classify "foo"` takes the `"foo"` branch.

## eco

The partial application of `==` and the string-literal `case` both register `Elm_Kernel_Utils_equal`, so both uses must agree on one kernel signature, with the PAP using the all-boxed ABI. Exercises CGEN_038 and KERN_006 in design_docs/invariants.csv; the kernel ABI policy lives in compiler/src/Compiler/GenerateMlir/KernelAbi.elm.

-}

-- CHECK: filtered: [5,5]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        "bar" ->
            "matched bar"

        _ ->
            "other"


main =
    let
        eq = (==)
        filtered = List.filter (eq 5) [1, 2, 5, 3, 5]
        _ = Debug.log "filtered" filtered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
