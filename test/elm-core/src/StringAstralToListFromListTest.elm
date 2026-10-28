module StringAstralToListFromListTest exposing (main)

{-| G1/E3: toList yields one Char per code point, as in Elm (Char is a Unicode
code point in i32), so "a😀b" gives 3 Chars with the emoji intact (code
128512). fromList writes a Char above U+FFFF back as a surrogate pair, so the
fromList ∘ toList round-trip holds and a list built from codes re-encodes to
the same string (length in UTF-16 units: 4).
-}

-- CHECK: tolist_len: 3
-- CHECK: tolist_codes: [97, 128512, 98]
-- CHECK: roundtrip_ok: True
-- CHECK: fromlist_ok: True
-- CHECK: fromlist_units: 4

import Html exposing (text)


main =
    let
        built =
            String.fromList (List.map Char.fromCode [ 0x61, 0x0001F600, 0x62 ])

        _ =
            Debug.log "tolist_len" (List.length (String.toList "a😀b"))

        _ =
            Debug.log "tolist_codes" (List.map Char.toCode (String.toList "a😀b"))

        _ =
            Debug.log "roundtrip_ok" (String.fromList (String.toList "a😀b") == "a😀b")

        _ =
            Debug.log "fromlist_ok" (built == "a😀b")

        _ =
            Debug.log "fromlist_units" (String.length built)
    in
    text "done"
