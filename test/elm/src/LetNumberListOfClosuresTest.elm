module LetNumberListOfClosuresTest exposing (main)

{-| Probe: a `number` captured by closures stored in a LIST, each applied at
`Float`. Both closures force the captured `n` to `Float`. Correct: with input
1.0, [1.0*30, 1.0+30] = [30, 31].

-}

-- CHECK: listclos: [30, 31]

import Html exposing (text)


main =
    let
        n =
            30

        fns =
            [ \x -> x * n, \x -> x + n ]

        result =
            List.map (\f -> round (f 1.0)) fns

        _ =
            Debug.log "listclos" result
    in
    text "done"
