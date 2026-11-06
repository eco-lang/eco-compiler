module LetDestructTupleNestedTest exposing (main)

{-| Tuple patterns in `let` bindings: a flat pair, a pair of pairs destructured in one
pattern, and a pair whose second part is bound by name and destructured by a later
binding.

The nested sum is `3 + 4 + 5 - 6 + 2 = 8`; the chained one is `1 + 2 + 3 = 6`.

-}

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
