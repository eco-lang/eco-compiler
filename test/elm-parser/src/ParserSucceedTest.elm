module ParserSucceedTest exposing (main)

-- CHECK: succeed_result: Ok 42
-- CHECK: succeed_string: Ok "hello"

import Html exposing (text)
import Parser


main =
    let
        _ = Debug.log "succeed_result" (Parser.run (Parser.succeed 42) "anything")
        _ = Debug.log "succeed_string" (Parser.run (Parser.succeed "hello") "")
    in
    text "done"
