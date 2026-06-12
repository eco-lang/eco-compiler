module LetNumberListFixedTest exposing (main)

{-| Probe: fixed-length list pattern (`[ a, b ]`) binding two `number` elements,
both used at `Float`. Correct: 30*1.5 + 40*1.5 = 45 + 60 = 105.
-}

-- CHECK: listfixed: 105

import Html exposing (text)


main =
    let
        result =
            case [ 30, 40 ] of
                [ a, b ] ->
                    round (a * 1.5) + round (b * 1.5)

                _ ->
                    0

        _ =
            Debug.log "listfixed" result
    in
    text "done"
