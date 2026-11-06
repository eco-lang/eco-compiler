module ListMap2FloatTest exposing (main)

{-| `List.map2` and `List.map3` on `List Float` pass the Float elements unchanged to
the mapping function, giving the expected sums and products.

`Debug.log` prints a whole-number Float without a decimal point, as in
`[11,22,33]`.

-}

-- CHECK: map2Add: [11,22,33]
-- CHECK: map2Mul: [3,5]
-- CHECK: map2Decimals: [4.5,6.5]
-- CHECK: map3: [111,222]

import Html exposing (text)


main =
    let
        _ = Debug.log "map2Add" (List.map2 (+) [1.0, 2.0, 3.0] [10.0, 20.0, 30.0])
        _ = Debug.log "map2Mul" (List.map2 (*) [1.5, 2.5] [2.0, 2.0])
        _ = Debug.log "map2Decimals" (List.map2 (+) [1.5, 2.5] [3.0, 4.0])
        _ = Debug.log "map3" (List.map3 (\a b c -> a + b + c) [1.0, 2.0] [10.0, 20.0] [100.0, 200.0])
    in
    text "done"
