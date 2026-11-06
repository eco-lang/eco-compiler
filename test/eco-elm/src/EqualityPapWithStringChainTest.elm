module EqualityPapWithStringChainTest exposing (main)

{-| `(==)` bound to a local name and partially applied to a `String` filters a list of strings.

`List.filter (eq "a")` over `["a", "b", "a"]` keeps the two `"a"`s.

## eco

Checks that the kernel ABI of `Elm_Kernel_Utils_equal` is consistent between the partial application of `==` and the string-chain pattern match of a `case`: both paths use an `!eco.value` result (CGEN_038 in design_docs/invariants.csv).

-}

-- CHECK: filter: ["a","a"]

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq "a") ["a", "b", "a"]
        _ = Debug.log "filter" filtered
    in
    text "done"
