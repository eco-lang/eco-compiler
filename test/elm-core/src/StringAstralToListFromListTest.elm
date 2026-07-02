module StringAstralToListFromListTest exposing (main)

{-| G1/E3: toList yields one Char per UTF-16 code unit in Eco (Char is i16), so
"a😀b" -> 4 Chars (the astral char splits into its two surrogate halves). The
fromList ∘ toList round-trip still holds because each half is written back
verbatim. Documents the deliberate i16-Char divergence from Elm.
-}

-- CHECK: tolist_len: 4
-- CHECK: roundtrip_ok: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "tolist_len" (List.length (String.toList "a😀b"))

        _ =
            Debug.log "roundtrip_ok" (String.fromList (String.toList "a😀b") == "a😀b")
    in
    text "done"
