module LetNumberFoldrTest exposing (main)

{-| A let-bound list of `number` literals is folded by `List.foldr` with a
`Float` accumulator, which makes its elements `Float`s.

`List.foldr (\x acc -> x * 1.5 + acc) 0.0 [ 30, 40 ]` is 45 + 60 + 0, so the
test logs 105.

-}

-- CHECK: foldr: 105

import Html exposing (text)


main =
    let
        xs =
            [ 30, 40 ]

        result =
            round (List.foldr (\x acc -> x * 1.5 + acc) 0.0 xs)

        _ =
            Debug.log "foldr" result
    in
    text "done"
