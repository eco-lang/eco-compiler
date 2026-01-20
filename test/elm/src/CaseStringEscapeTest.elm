module CaseStringEscapeTest exposing (main)

{-| Test case expression with string patterns containing escape characters.
-}

-- CHECK: esc1: "newline"
-- CHECK: esc2: "tab"
-- CHECK: esc3: "quote"
-- CHECK: esc4: "other"

import Html exposing (text)


describeEscape s =
    case s of
        "\n" -> "newline"
        "\t" -> "tab"
        "\"" -> "quote"
        _ -> "other"


main =
    let
        _ = Debug.log "esc1" (describeEscape "\n")
        _ = Debug.log "esc2" (describeEscape "\t")
        _ = Debug.log "esc3" (describeEscape "\"")
        _ = Debug.log "esc4" (describeEscape "hello")
    in
    text "done"
