module ParserAdvancedKeywordTest exposing (main)

{-| `Parser.Advanced.keyword` and `Parser.Advanced.symbol` succeed on input that starts with their token.

`keyword_ok` runs the keyword `"let"` on `"let x"`, where the keyword is
followed by a space. `symbol_ok` runs the symbol `"="` on `"="`. Each checks
only that the run returns `Ok`.

Among what is not tested: failures, including a keyword followed by a letter
or digit, and the problem values reported.
-}

-- CHECK: keyword_ok: True
-- CHECK: symbol_ok: True

import Html exposing (text)
import Parser.Advanced as PA


type Prob
    = ExpectedLet
    | ExpectedEq


main =
    let
        kp = PA.keyword (PA.Token "let" ExpectedLet)
        sp = PA.symbol (PA.Token "=" ExpectedEq)
        r1 = PA.run kp "let x"
        _ = Debug.log "keyword_ok"
            (case r1 of
                Ok _ -> True
                Err _ -> False
            )
        r2 = PA.run sp "="
        _ = Debug.log "symbol_ok"
            (case r2 of
                Ok _ -> True
                Err _ -> False
            )
    in
    text "done"
