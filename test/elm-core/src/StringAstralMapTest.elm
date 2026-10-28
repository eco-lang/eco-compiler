module StringAstralMapTest exposing (main)

{-| G1/E5: map applies the function once per code point, as in Elm (Char is a
Unicode code point in i32), so mapping every Char of "a😀b" to 'x' yields
"xxx". map identity round-trips, and a map that produces an astral Char writes
it back as a surrogate pair (2 UTF-16 units).
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
