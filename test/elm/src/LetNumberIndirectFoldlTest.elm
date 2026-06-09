module LetNumberIndirectFoldlTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) reached when the `number` is the
`Float` seed of `List.foldl (+)`. The seed `acc0 = 0` must specialize to `Float`
because the fold accumulates over a `Float` list. Correct: 0 + 1.5 + 2.5 = 4.

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
