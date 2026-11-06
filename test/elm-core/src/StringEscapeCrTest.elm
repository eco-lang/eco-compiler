module StringEscapeCrTest exposing (main)

{-| The `\r` escape in a string literal is a carriage return, code point 13.

Each check logs the character codes of a string:

  - `"\r"` alone;
  - `\r` among the other escapes `\n`, `\t`, `\\` and `\"`, ordinary letters,
    and `\u{000D}`;
  - `"\r\n"`;
  - `\r` inside a triple-quoted string.

It also checks that a string built from code 13 matches the `"\r"` pattern in a
`case`, and that `"\r\n"` has length 2.

-}

-- CHECK: cr: [13]
-- CHECK: mixed: [97,13,98,10,99,9,100,92,101,34,102,13,103]
-- CHECK: crlf: [13,10]
-- CHECK: triple: [120,13,121]
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
