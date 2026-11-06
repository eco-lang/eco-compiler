module ConsDevirtTest exposing (main)

{-| The list constructor `(::)` passed as a function value to a recursive
higher-order function.

`applyCons` and `applyConsS` recurse down to zero carrying the function along,
then apply it twice to a starting list. The `Int` version conses two values onto
`[ 5 ]` to build `[ 3, 4, 5 ]`, which sums to 12, and the `String` version conses
two onto `[]` to build `[ "a", "b" ]`, which concatenates to `"ab"`.

## eco

Exercises kernel devirtualization (LSS_016 in design_docs/invariants.csv; plans/lss-dispatch-value-extraction.md, section E9.2). `(::)` is the kernel value `List.cons`; with the solver and lambda-set specialization on, the `f` call sites in the recursion carry the singleton lambda set of `List.cons` and become direct kernel calls. The `Int` version reaches the unboxed-head `cons_Int` variant and the `String` version the boxed `cons`. The output must match a build without lambda sets (LSS_005 in design_docs/invariants.csv).

Unit-level pin: compiler/tests/Compiler/Monomorphize/Solver/E92ConsDevirtTest.elm.

-}

-- CHECK: result: 12
-- CHECK: result2: "ab"

import Html exposing (text)


applyCons : (Int -> List Int -> List Int) -> Int -> List Int
applyCons f n =
    if n <= 0 then
        f (n + 3) (f (n + 4) [ n + 5 ])

    else
        applyCons f (n - 1)


applyConsS : (String -> List String -> List String) -> Int -> List String
applyConsS f n =
    if n <= 0 then
        f "a" (f "b" [])

    else
        applyConsS f (n - 1)


main =
    let
        result =
            List.sum (applyCons (::) 2)

        _ =
            Debug.log "result" result

        result2 =
            String.concat (applyConsS (::) 2)

        _ =
            Debug.log "result2" result2
    in
    text "done"
