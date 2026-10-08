module StringEscapeCrTest exposing (main)

{-| The `\r` escape in string literals is a carriage return (U+000D). The native
backend's literal decoders (bytecode `StringTable.unescapeStringSlow`, text
`Pretty.escapeForMlir`) used to keep it as a backslash and an `r`, while the JS
backend was right. Every escape is checked by its code points, next to its
neighbours, in a `"""` string, and as a `case` pattern.
-}

-- CHECK: cr: [13]
-- CHECK: mixed: [97, 13, 98, 10, 99, 9, 100, 92, 101, 34, 102, 13, 103]
-- CHECK: crlf: [13, 10]
-- CHECK: triple: [120, 13, 121]
-- CHECK: pattern: "carriage return"
-- CHECK: length: 2

import Html exposing (text)


codes : String -> List Int
codes s =
    List.map Char.toCode (String.toList s)


describe : String -> String
describe s =
    case s of
        "\r" ->
            "carriage return"

        "\n" ->
            "newline"

        _ ->
            "other"


main =
    let
        _ =
            Debug.log "cr" (codes "\r")

        _ =
            Debug.log "mixed" (codes "a\rb\nc\td\\e\"f\u{000D}g")

        _ =
            Debug.log "crlf" (codes "\r\n")

        _ =
            Debug.log "triple" (codes """x\ry""")

        _ =
            Debug.log "pattern" (describe (String.fromList [ Char.fromCode 13 ]))

        _ =
            Debug.log "length" (String.length "\r\n")
    in
    text "done"
