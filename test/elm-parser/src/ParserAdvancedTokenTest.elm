module ParserAdvancedTokenTest exposing (main)

-- CHECK: matched: True
-- CHECK: failed: True

import Html exposing (text)
import Parser.Advanced as PA


type Prob
    = ExpectingEquals


p : PA.Parser c Prob ()
p =
    PA.token (PA.Token "=" ExpectingEquals)


main =
    let
        ok_ = PA.run p "="
        _ = Debug.log "matched"
            (case ok_ of
                Ok _ -> True
                Err _ -> False
            )
        bad = PA.run p "x"
        _ = Debug.log "failed"
            (case bad of
                Err _ -> True
                Ok _ -> False
            )
    in
    text "done"
