module LetNumberListConsHeadTest exposing (main)

{-| Probe: `number` list head extracted via a `::` cons pattern, used at `Float`.
`buildPartialContainer` returns `Nothing` for `HintList`, so this exercises a
destructure path with no number demand-refinement support. Correct: 30*1.5 = 45.
-}

-- CHECK: listcons: 45

import Html exposing (text)


main =
    let
        result =
            case [ 30, 40 ] of
                h :: _ ->
                    round (h * 1.5)

                _ ->
                    0

        _ =
            Debug.log "listcons" result
    in
    text "done"
