module ParserIntTest exposing (main)

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
