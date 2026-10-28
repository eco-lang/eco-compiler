module CharAstralTupleTest exposing (main)

{-| An astral Char stored unboxed in a tuple slot (kind 3) reads back as the
same code point, in a Tuple2 and a Tuple3, and Debug.log prints it as itself.
-}

-- CHECK: tup2_code: 128512
-- CHECK: tup3_code: 119070
-- CHECK: tup2_show: (1, '😀')
-- CHECK: tup3_show: ('a', '𝄞', 2)


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
