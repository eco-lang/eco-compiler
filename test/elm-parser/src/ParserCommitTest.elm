module ParserCommitTest exposing (main)

-- CHECK: committed: True

import Html exposing (text)
import Parser exposing ((|.))


p : Parser.Parser Int
p =
    Parser.oneOf
        [ Parser.succeed 0
            |. Parser.symbol "a"
            |. Parser.commit ()
            |. Parser.symbol "b"
        , Parser.succeed 1 |. Parser.symbol "a"
        ]


main =
    let
        result = Parser.run p "ax"
        _ = Debug.log "committed"
            (case result of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
