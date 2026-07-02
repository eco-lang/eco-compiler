module StringAstralMapTest exposing (main)

{-| G1/E5: map applies the function once per UTF-16 code unit in Eco (Char is
i16), so mapping every unit of "a😀b" to 'x' yields 4 chars (the astral char is
two units). map identity round-trips (each unit preserved). Documents the
deliberate i16-Char divergence from Elm's code-point map.
-}

-- CHECK: map_const_len: 4
-- CHECK: map_id_ok: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "map_const_len" (String.length (String.map (\_ -> 'x') "a😀b"))

        _ =
            Debug.log "map_id_ok" (String.map identity "a😀b" == "a😀b")
    in
    text "done"
