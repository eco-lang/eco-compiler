module ParserKeywordTest exposing (main)

{-| Checks that `Parser.keyword` matches a whole word but not the prefix of a longer identifier.

`keyword "let"` succeeds on `"let "`, where a space follows, and fails on
`"letter"`, where the next character could continue the word. Compare
`ParserTokenTest`, where `token "let"` succeeds on `"letter"`.
-}

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
