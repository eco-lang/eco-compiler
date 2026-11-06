module EqualityBoolMaybeTest exposing (main)

{-| Equality on `Maybe Bool` compares the wrapped `Bool` values and tells
`Nothing` apart from `Just`.

`Just True` equals `Just True` and `Just False` equals `Just False`, while
`Just True` and `Just False` differ in either order. `Nothing` equals `Nothing`
and differs from both `Just True` and `Just False`.

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
