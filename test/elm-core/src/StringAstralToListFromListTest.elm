module StringAstralToListFromListTest exposing (main)

{-| `String.toList` gives one `Char` for a character outside the Basic
Multilingual Plane, such as an emoji, and `String.fromList` turns it back into
the same string.

`String.toList "a😀b"` has 3 elements with codes `[97,128512,98]`, and
`String.fromList` of it equals `"a😀b"`. A list made with `Char.fromCode` from
`0x61`, `0x1F600` and `0x62` also gives `"a😀b"`, whose `String.length` is 4
because `String.length` counts UTF-16 units and the emoji takes two.

-}

-- CHECK: tolist_len: 3
-- CHECK: tolist_codes: [97,128512,98]
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
