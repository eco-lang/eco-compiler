module ParserTokenTest exposing (main)

{-| Checks that `Parser.token` matches a prefix even when an identifier character follows.

`token "let"` succeeds on `"letter"`. Compare `ParserKeywordTest`, where
`keyword "let"` fails on the same input.
-}

-- CHECK: letter: True

import Html exposing (text)
import Parser


main =
    let
        result = Parser.run (Parser.token "let") "letter"
        _ = Debug.log "letter"
            (case result of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
