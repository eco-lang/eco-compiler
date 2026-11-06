module JsonIssue18IndexNegativeTest exposing (main)

{-| `Json.Decode.index` checks for an index past the end but not for a negative one.

<https://github.com/elm/json/issues/18>

Elm 0.19.1 (elm/json 1.1.4) decodes `array[-1]`, which is `undefined`: `index -1 (succeed ())`
on `[1]` succeeds with `Ok ()`. An index outside the array must fail, as `index 1` does.

-}

-- CHECK: {{(^|\n)index 1: Err}}
-- CHECK: {{(^|\n)index -1: Err}}

import Html exposing (text)
import Json.Decode as JD


main =
    let
        _ =
            Debug.log "index 1" (JD.decodeString (JD.index 1 (JD.succeed ())) "[1]")

        _ =
            Debug.log "index -1" (JD.decodeString (JD.index -1 (JD.succeed ())) "[1]")
    in
    text "done"
