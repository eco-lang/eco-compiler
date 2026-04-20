module ParserAdvancedKeywordTest exposing (main)

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
