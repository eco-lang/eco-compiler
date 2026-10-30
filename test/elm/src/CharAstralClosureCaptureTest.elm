module CharAstralClosureCaptureTest exposing (main)

{-| An astral Char captured unboxed by a closure (capture kind 3) and by a
partial application reads back as the same code point when the closure runs,
including through List.map (generic apply).
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
