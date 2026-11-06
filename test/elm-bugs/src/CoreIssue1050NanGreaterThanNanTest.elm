module CoreIssue1050NanGreaterThanNanTest exposing (main)

{-| `NaN > NaN` and `NaN >= NaN` are False.

<https://github.com/elm/core/issues/1050>

An ordered comparison involving NaN is false under IEEE 754, as `NaN < NaN` already is in Elm.
Elm 0.19.1 returns True for both.

-}

-- CHECK: nan > nan: False
-- CHECK: nan >= nan: False

import Html exposing (text)


nan : Float
nan =
    0 / 0


main =
    let
        _ =
            Debug.log "nan > nan" (nan > nan)

        _ =
            Debug.log "nan >= nan" (nan >= nan)
    in
    text "done"
