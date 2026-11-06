module StringMapFilterTest exposing (main)

{-| Checks that `String.map` transforms every character and `String.filter` keeps only the characters its predicate accepts.

`String.map Char.toUpper "hello"` gives `"HELLO"`, and removing `'e'` and `'o'`
from `"hello"` gives `"hll"`.

-}

-- CHECK: map1: "HELLO"
-- CHECK: filter1: "hll"

import Html exposing (text)

main =
    let
        _ = Debug.log "map1" (String.map Char.toUpper "hello")
        _ = Debug.log "filter1" (String.filter (\c -> c /= 'e' && c /= 'o') "hello")
    in
    text "done"
