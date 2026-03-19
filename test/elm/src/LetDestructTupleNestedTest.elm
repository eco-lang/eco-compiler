module LetDestructTupleNestedTest exposing (main)

{-| Test nested and chained tuple destructuring in let bindings. -}

-- CHECK: basic: 3
-- CHECK: nested: 8
-- CHECK: chain: 6

import Html exposing (text)


main =
    let
        (a, b) = (1, 2)
        ((c, d), (e, f)) = ((3, 4), (5, 6))
        (g, rest) = (1, (2, 3))
        (h, i) = rest
        _ = Debug.log "basic" (a + b)
        _ = Debug.log "nested" (c + d + e - f + 2)
        _ = Debug.log "chain" (g + h + i)
    in
    text "done"
