module ParserAdvancedRunTest exposing (main)

-- CHECK: succeeded: Ok 42

import Html exposing (text)
import Parser.Advanced as PA


p : PA.Parser c pr Int
p =
    PA.succeed 42


main =
    let
        result = PA.run p ""
        _ = Debug.log "succeeded" result
    in
    text "done"
