module ParserAllTest exposing (main)
import Html exposing (text)
import Parser exposing ((|.), (|=))

main =
    let
        _ = Debug.log "keyword" (Parser.run (Parser.keyword "let") "let x")
        _ = Debug.log "symbol" (Parser.run (Parser.symbol "=") "=")
        _ = Debug.log "chompUntil" (Parser.run (Parser.chompUntil "end") "abc end")
    in
    text "done"
