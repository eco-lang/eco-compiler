module CharAstralRecordFieldTest exposing (main)

{-| An astral Char stored unboxed in a record field (slot kind 3, the code point
zero-extended to the 64-bit slot, REP_HEAP_002) reads back as the same code
point, next to an Int field, and through a record update.
-}

-- CHECK: rec_c: 128512
-- CHECK: rec_n: 7
-- CHECK: rec_updated: 119070
-- CHECK: rec_eq: True


import Html exposing (text)


type alias Glyph =
    { c : Char, n : Int }


mk : Char -> Int -> Glyph
mk c n =
    { c = c, n = n }


main =
    let
        g =
            mk '😀' 7

        h =
            { g | c = Char.fromCode 0x0001D11E }

        _ =
            Debug.log "rec_c" (Char.toCode g.c)

        _ =
            Debug.log "rec_n" g.n

        _ =
            Debug.log "rec_updated" (Char.toCode h.c)

        _ =
            Debug.log "rec_eq" (g == { c = '😀', n = 7 })
    in
    text "done"
