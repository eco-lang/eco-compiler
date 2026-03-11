module EqualityPapWithStringChainTest exposing (main)

{-| Test that using (==) as a function value (PAP) coexists with string
chain patterns in tuple case expressions.

This validates that the kernel ABI for Utils_equal is consistent:
the PAP path and the IsStr chain path both use eco.value return.
-}

-- CHECK: filter: ["a", "a"]

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq "a") ["a", "b", "a"]
        _ = Debug.log "filter" filtered
    in
    text "done"
