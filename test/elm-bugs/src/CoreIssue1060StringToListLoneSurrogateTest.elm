module CoreIssue1060StringToListLoneSurrogateTest exposing (main)

{-| `String.toList` loops forever on a string holding a lone low surrogate.

<https://github.com/elm/core/issues/1060>

Elm 0.19.1 hangs on `String.toList "\u{dd56}"` (and runs out of memory; the heap is capped here). It must return a list of
one Char.

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
