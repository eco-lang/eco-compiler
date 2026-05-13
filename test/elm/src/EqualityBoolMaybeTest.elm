module EqualityBoolMaybeTest exposing (main)

{-| `Maybe Bool` equality. `Just _ == Just _` recurses into `eqHelp` on
the payload, so the embedded-constant collapse on the inner Bool is
exposed even when the wrapper forces a real kernel call. `Nothing` is
itself an embedded constant.
-}

-- CHECK: justTT: True
-- CHECK: justTF: False
-- CHECK: justFF: True
-- CHECK: justFT: False
-- CHECK: nothingNothing: True
-- CHECK: justTrueNothing: False
-- CHECK: nothingJustFalse: False

import Html exposing (text)


main =
    let
        jt : Maybe Bool
        jt = Just True

        jf : Maybe Bool
        jf = Just False

        nb : Maybe Bool
        nb = Nothing

        _ = Debug.log "justTT" (jt == Just True)
        _ = Debug.log "justTF" (jt == jf)
        _ = Debug.log "justFF" (jf == Just False)
        _ = Debug.log "justFT" (jf == Just True)
        _ = Debug.log "nothingNothing" (nb == Nothing)
        _ = Debug.log "justTrueNothing" (jt == nb)
        _ = Debug.log "nothingJustFalse" (nb == jf)
    in
    text "done"
