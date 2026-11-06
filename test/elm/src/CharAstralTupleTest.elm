module CharAstralTupleTest exposing (main)

{-| An astral `Char` (code point above 0xFFFF) in a pair and in a 3-tuple keeps
its code point when read with `Tuple.second` and with a destructuring `let`
pattern, and `Debug.log` prints each tuple with the characters themselves.
-}

-- CHECK: tup2_code: 128512
-- CHECK: tup3_code: 119070
-- CHECK: tup2_show: (1,'😀')
-- CHECK: tup3_show: ('a','𝄞',2)


import Html exposing (text)


pair : Int -> Char -> ( Int, Char )
pair n c =
    ( n, c )


main =
    let
        t2 =
            pair 1 '😀'

        t3 =
            ( 'a', Char.fromCode 0x0001D11E, 2 )

        ( _, c3, _ ) =
            t3

        _ =
            Debug.log "tup2_code" (Char.toCode (Tuple.second t2))

        _ =
            Debug.log "tup3_code" (Char.toCode c3)

        _ =
            Debug.log "tup2_show" t2

        _ =
            Debug.log "tup3_show" t3
    in
    text "done"
