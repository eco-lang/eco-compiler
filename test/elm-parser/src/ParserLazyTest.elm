module ParserLazyTest exposing (main)

-- CHECK: nested: True

import Html exposing (text)
import Parser exposing ((|.))


parens : Parser.Parser ()
parens =
    Parser.succeed ()
        |. Parser.symbol "("
        |. Parser.oneOf
            [ Parser.lazy (\_ -> parens)
            , Parser.succeed ()
            ]
        |. Parser.symbol ")"


main =
    let
        result = Parser.run parens "((()))"
        _ = Debug.log "nested"
            (case result of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
