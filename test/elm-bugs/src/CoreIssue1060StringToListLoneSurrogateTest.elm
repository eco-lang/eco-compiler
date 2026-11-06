module CoreIssue1060StringToListLoneSurrogateTest exposing (main)

{-| `String.toList` of a string holding a lone low surrogate returns one `Char`.

<https://github.com/elm/core/issues/1060>

Elm 0.19.1 loops forever on `String.toList "\u{dd56}"` until it runs out of memory; the test caps
the JavaScript heap so that this fails quickly.

-}

-- CHECK: length: 1
-- ENV: NODE_OPTIONS=--max-old-space-size=256

import Html exposing (text)


main =
    let
        _ =
            Debug.log "length" (List.length (String.toList "\u{dd56}"))
    in
    text "done"
