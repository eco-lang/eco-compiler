module ParserLazyTest exposing (main)

{-| Checks that `Parser.lazy` lets a parser refer to itself, by matching nested parentheses.

`parens` matches `(`, then either another `parens` or nothing, then `)`.
`"((()))"` parses successfully.
-}

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
