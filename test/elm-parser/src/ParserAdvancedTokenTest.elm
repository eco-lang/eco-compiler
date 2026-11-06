module ParserAdvancedTokenTest exposing (main)

{-| `Parser.Advanced.token` succeeds on input that starts with the token and fails on input that does not.

`matched` runs the token `"="` on `"="` and checks for `Ok`; `failed` runs it
on `"x"` and checks for `Err`. Neither inspects the dead ends.
-}

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
