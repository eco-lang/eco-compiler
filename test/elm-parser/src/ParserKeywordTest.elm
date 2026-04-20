module ParserKeywordTest exposing (main)

-- CHECK: letok: True
-- CHECK: letterfail: True

import Html exposing (text)
import Parser


main =
    let
        ok_ = Parser.run (Parser.keyword "let") "let "
        _ = Debug.log "letok"
            (case ok_ of
                Ok _ -> True
                Err _ -> False
            )
        bad = Parser.run (Parser.keyword "let") "letter"
        _ = Debug.log "letterfail"
            (case bad of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
