module CaseStringEmptyPatternTest exposing (main)

{-| Test case-match on String against empty-string and non-empty literals.

Exercises the lowering path from `parseYesNoResponse`-style patterns that
calls `Elm_Kernel_Utils_equal` during decision-tree lowering of string
patterns. Reported at bootstrap stage 6 as:

    'llvm.call' op operand type mismatch for operand 1:
    'i64' != '!llvm.ptr<1>'

in `Builder_Reporting_parseYesNoResponse_$_30611`.

-}

-- CHECK: empty: "yes"
-- CHECK: Y: "yes"
-- CHECK: y: "yes"
-- CHECK: n: "no"
-- CHECK: maybe: "retry"


import Html exposing (text)


parseYesNo : String -> String
parseYesNo input =
    case input of
        "" ->
            "yes"

        "Y" ->
            "yes"

        "y" ->
            "yes"

        "n" ->
            "no"

        _ ->
            "retry"


main =
    let
        _ =
            Debug.log "empty" (parseYesNo "")

        _ =
            Debug.log "Y" (parseYesNo "Y")

        _ =
            Debug.log "y" (parseYesNo "y")

        _ =
            Debug.log "n" (parseYesNo "n")

        _ =
            Debug.log "maybe" (parseYesNo "maybe")
    in
    text "done"
