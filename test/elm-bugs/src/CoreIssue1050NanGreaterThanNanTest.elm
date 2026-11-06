module CoreIssue1050NanGreaterThanNanTest exposing (main)

{-| `NaN > NaN` and `NaN >= NaN` are True.

<https://github.com/elm/core/issues/1050>

Elm 0.19.1 returns True for both. Every ordered comparison involving NaN is false (IEEE 754, and
JavaScript), as `NaN < NaN` already is in Elm.

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
