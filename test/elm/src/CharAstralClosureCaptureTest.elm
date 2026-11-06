module CharAstralClosureCaptureTest exposing (main)

{-| An astral `Char` (code point above 0xFFFF) referred to by a lambda, or
supplied as the first argument of a partially applied function, keeps its code
point when the function is called later through `List.map`.

`addCode` returns a lambda that adds the character's code to its argument, and
`giveBack` returns a lambda that returns the character. `pairUp '😀'` is
partially applied and mapped over `[ 1, 2 ]`, and each resulting pair is summed.

-}

-- CHECK: cap_add: [128513,98]
-- CHECK: cap_return: [128512,119070]
-- CHECK: pap_pairs: [128513,128514]


import Html exposing (text)


addCode : Char -> (Int -> Int)
addCode c =
    \n -> n + Char.toCode c


giveBack : Char -> (() -> Char)
giveBack c =
    \() -> c


pairUp : Char -> Int -> ( Int, Char )
pairUp c n =
    ( n, c )


main =
    let
        adders =
            [ addCode '😀', addCode 'a' ]

        givers =
            [ giveBack '😀', giveBack (Char.fromCode 0x0001D11E) ]

        _ =
            Debug.log "cap_add" (List.map (\f -> f 1) adders)

        _ =
            Debug.log "cap_return" (List.map (\f -> Char.toCode (f ())) givers)

        _ =
            Debug.log "pap_pairs"
                (List.map (pairUp '😀') [ 1, 2 ]
                    |> List.map (\( n, c ) -> n + Char.toCode c)
                )
    in
    text "done"
