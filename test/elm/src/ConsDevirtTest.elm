module ConsDevirtTest exposing (main)

{-| E9.2 kernel devirtualization (LSS_016, plans/lss-dispatch-value-extraction.md §E9.2).

`(::)` — the kernel value `List.cons` — is passed as a function value to
recursion-protected HOFs. Flag-on (solver+LSS) the `f …` dispatch sites
carry the singleton {k|List.cons} and are devirtualized to DIRECT kernel
calls (the Int leg additionally exercises the typed `cons_Int` unboxed-head
variant; the String leg the boxed `cons`). The CHECKs below must print the
same answers as the flag-off build (LSS_005).

Unit-level pin: compiler/tests/TestLogic/Generate/CodeGen/E92ConsDevirtTest.elm.

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
