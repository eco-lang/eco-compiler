module StringAstralFoldTest exposing (main)

{-| G1/E2: foldl/foldr visit one Char per code point, as in Elm: a surrogate
pair is combined into one Char (Char is a Unicode code point in i32,
REP_ABI_001 / CGEN_015), so "😀" folds once and "a😀b" three times. foldr
walks back and combines a low surrogate with the high one before it, so it
sees the same Chars in reverse order.
-}

-- CHECK: foldl_astral: 1
-- CHECK: foldl_mixed: 3
-- CHECK: foldr_mixed: 3
-- CHECK: foldl_codes: [98,128512,97]
-- CHECK: foldr_codes: [97,128512,98]

import Html exposing (text)


main =
    let
        _ =
            Debug.log "foldl_astral" (String.foldl (\_ n -> n + 1) 0 "😀")

        _ =
            Debug.log "foldl_mixed" (String.foldl (\_ n -> n + 1) 0 "a😀b")

        _ =
            Debug.log "foldr_mixed" (String.foldr (\_ n -> n + 1) 0 "a😀b")

        _ =
            Debug.log "foldl_codes" (String.foldl (\c acc -> Char.toCode c :: acc) [] "a😀b")

        _ =
            Debug.log "foldr_codes" (String.foldr (\c acc -> Char.toCode c :: acc) [] "a😀b")
    in
    text "done"
