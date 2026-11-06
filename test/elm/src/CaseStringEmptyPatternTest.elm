module CaseStringEmptyPatternTest exposing (main)

{-| A case expression on a `String` matches the empty-string literal `""`
alongside non-empty literal patterns and a wildcard.

`parseYesNo` maps `""`, `"Y"` and `"y"` to `"yes"`, `"n"` to `"no"`, and any
other string to `"retry"`. The test calls it with each literal and with
`"maybe"`, which reaches the wildcard.

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
