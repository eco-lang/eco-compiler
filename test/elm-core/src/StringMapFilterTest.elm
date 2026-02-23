module StringMapFilterTest exposing (main)

-- CHECK: map1: "HELLO"
-- CHECK: filter1: "hll"

import Html exposing (text)

main =
    let
        _ = Debug.log "map1" (String.map Char.toUpper "hello")
        _ = Debug.log "filter1" (String.filter (\c -> c /= 'e' && c /= 'o') "hello")
    in
    text "done"
