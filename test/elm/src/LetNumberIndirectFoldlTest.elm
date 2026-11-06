module LetNumberIndirectFoldlTest exposing (main)

{-| A let-bound `number` used as the initial accumulator of `List.foldl (+)`
over a list of `Float`s is a `Float`.

`List.foldl (+) acc0 [ 1.5, 2.5 ]` with `acc0 = 0` is 4.0, logged as 4.

-}

-- CHECK: foldl: 4

import Html exposing (text)


main =
    let
        foldlN =
            let
                acc0 =
                    0
            in
            round (List.foldl (+) acc0 [ 1.5, 2.5 ])

        _ =
            Debug.log "foldl" foldlN
    in
    text "done"
