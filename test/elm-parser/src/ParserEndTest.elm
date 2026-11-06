module ParserEndTest exposing (main)

{-| `Parser.end` succeeds only when no input is left.

The parser reads the symbol `"abc"` and then `end`. `at_end` runs it on
`"abc"` and checks for `Ok`; `not_end` runs it on `"abcx"` and checks for
`Err`.
-}

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
