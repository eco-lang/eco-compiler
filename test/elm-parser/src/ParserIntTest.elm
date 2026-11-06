module ParserIntTest exposing (main)

{-| Checks that `Parser.int` reads a decimal integer and fails on non-numeric input.

`"123456"` parses to `Ok 123456`; `"abc"` gives an `Err`.
-}

-- CHECK: parsed_int: Ok 123456
-- CHECK: parse_fail: True

import Html exposing (text)
import Parser


main =
    let
        _ = Debug.log "parsed_int" (Parser.run Parser.int "123456")
        failed = Parser.run Parser.int "abc"
        _ = Debug.log "parse_fail"
            (case failed of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
