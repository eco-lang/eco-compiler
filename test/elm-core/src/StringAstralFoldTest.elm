module StringAstralFoldTest exposing (main)

{-| `String.foldl` and `String.foldr` visit a character outside the Basic
Multilingual Plane, such as an emoji, once, as one `Char`.

Counting with a fold gives 1 for `"😀"` and 3 for `"a😀b"`, from either end.
Consing each `Char.toCode` onto a list gives `[98,128512,97]` with `foldl` and
`[97,128512,98]` with `foldr`, so `foldr` sees the same characters in reverse
order, with the emoji whole (128512 is `0x1F600`).

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
