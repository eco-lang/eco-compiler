module CaseStringEscapeTest exposing (main)

{-| A case expression on a `String` matches literal patterns written with escape
sequences: a newline, a tab and a double quote.

The string `"hello"` matches none of them and reaches the wildcard.

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
