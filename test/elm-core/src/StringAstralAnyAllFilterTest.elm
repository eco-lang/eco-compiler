module StringAstralAnyAllFilterTest exposing (main)

{-| String.any, String.all, String.filter and String.foldr see one Char per code
point, as in Elm (Char is a Unicode code point in i32): a predicate on the
whole emoji matches it, and no predicate ever sees a surrogate half. filter
writes a kept astral Char back as a surrogate pair.
-}

-- CHECK: any_emoji: True
-- CHECK: any_half: False
-- CHECK: all_astral: True
-- CHECK: all_bmp: False
-- CHECK: filter_keep_ok: True
-- CHECK: filter_keep_len: 4
-- CHECK: filter_drop_ok: True
-- CHECK: foldr_string_ok: True


import Html exposing (text)


isEmoji : Char -> Bool
isEmoji c =
    Char.toCode c == 0x0001F600


isSurrogate : Char -> Bool
isSurrogate c =
    let
        n =
            Char.toCode c
    in
    n >= 0xD800 && n <= 0xDFFF


isAstral : Char -> Bool
isAstral c =
    Char.toCode c > 0xFFFF


main =
    let
        _ =
            Debug.log "any_emoji" (String.any isEmoji "a😀b")

        _ =
            Debug.log "any_half" (String.any isSurrogate "a😀b𝄞")

        _ =
            Debug.log "all_astral" (String.all isAstral "😀𝄞😀")

        _ =
            Debug.log "all_bmp" (String.all isAstral "😀a")

        _ =
            Debug.log "filter_keep_ok" (String.filter isAstral "a😀b𝄞c" == "😀𝄞")

        _ =
            Debug.log "filter_keep_len" (String.length (String.filter isAstral "a😀b𝄞c"))

        _ =
            Debug.log "filter_drop_ok" (String.filter (not << isAstral) "a😀b𝄞c" == "abc")

        _ =
            Debug.log "foldr_string_ok" (String.foldr String.cons "" "x😀y𝄞" == "x😀y𝄞")
    in
    text "done"
