module ParserEndTest exposing (main)

-- CHECK: at_end: True
-- CHECK: not_end: True

import Html exposing (text)
import Parser exposing ((|.))


myParser : Parser.Parser ()
myParser =
    Parser.succeed ()
        |. Parser.symbol "abc"
        |. Parser.end


main =
    let
        ok_ = Parser.run myParser "abc"
        _ = Debug.log "at_end"
            (case ok_ of
                Ok _ -> True
                Err _ -> False
            )
        bad = Parser.run myParser "abcx"
        _ = Debug.log "not_end"
            (case bad of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
