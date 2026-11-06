module StringAstralMapTest exposing (main)

{-| `String.map` applies its function once to a character outside the Basic
Multilingual Plane, such as an emoji, and can produce such a character.

Mapping every character of `"a😀b"` to `'x'` gives `"xxx"`, of length 3.
`String.map identity` returns `"a😀b"` unchanged. Mapping every character of
`"ab😀"` to `'😀'` gives `"😀😀😀"`, whose `String.length` is 6 because
`String.length` counts UTF-16 units and each emoji takes two.

-}

-- CHECK: map_const_len: 3
-- CHECK: map_const_ok: True
-- CHECK: map_id_ok: True
-- CHECK: map_to_astral_ok: True
-- CHECK: map_to_astral_len: 6

import Html exposing (text)


main =
    let
        _ =
            Debug.log "map_const_len" (String.length (String.map (\_ -> 'x') "a😀b"))

        _ =
            Debug.log "map_const_ok" (String.map (\_ -> 'x') "a😀b" == "xxx")

        _ =
            Debug.log "map_id_ok" (String.map identity "a😀b" == "a😀b")

        _ =
            Debug.log "map_to_astral_ok" (String.map (\_ -> '😀') "ab😀" == "😀😀😀")

        _ =
            Debug.log "map_to_astral_len" (String.length (String.map (\_ -> '😀') "ab😀"))
    in
    text "done"
