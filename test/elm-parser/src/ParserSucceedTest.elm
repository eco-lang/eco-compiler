module ParserSucceedTest exposing (main)

{-| Checks that `Parser.succeed` returns its value without consuming input.

`succeed 42` on `"anything"` gives `Ok 42`, which also shows that `Parser.run`
does not require the input to be fully consumed. `succeed "hello"` on the empty
string gives `Ok "hello"`.
-}

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
