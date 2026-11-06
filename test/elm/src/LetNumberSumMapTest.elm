module LetNumberSumMapTest exposing (main)

{-| A let-bound list of integer literals, mapped to `Float`s and summed, is used at
`Float`: `round (List.sum (List.map (\x -> x * 1.5) [ 30, 40 ]))` logs 105.
-}

-- CHECK: summap: 105

import Html exposing (text)


main =
    let
        xs =
            [ 30, 40 ]

        result =
            round (List.sum (List.map (\x -> x * 1.5) xs))

        _ =
            Debug.log "summap" result
    in
    text "done"
