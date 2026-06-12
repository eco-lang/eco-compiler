module LetNumberMaybeCaseDirectTest exposing (main)

{-| Probe: `Maybe number` matched DIRECTLY with a `case` pattern (`Just n`),
payload used at `Float` — distinct from the `Maybe.map` call-arg path. Correct:
30*1.5 = 45.
-}

-- CHECK: maybedirect: 45

import Html exposing (text)


main =
    let
        result =
            case Just 30 of
                Just n ->
                    round (n * 1.5)

                Nothing ->
                    0

        _ =
            Debug.log "maybedirect" result
    in
    text "done"
