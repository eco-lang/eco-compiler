module ArrayAppendCanonicalTest exposing (main)

{-| `Array.append` of two halves gives an array equal under `==` to `Array.initialize` of
the whole, for lengths 32, 64, 96, 128, 160 and 256.

The first half holds `0` to `n // 2 - 1` and the second `n // 2` to `n - 1`, so both sides
hold the same elements in the same order and each line should log `True`. Lengths 96 and 160
are multiples of 32 that are not powers of two.

-}

-- CHECK: append32: True
-- CHECK: append64: True
-- CHECK: append96: True
-- CHECK: append128: True
-- CHECK: append160: True
-- CHECK: append256: True

import Array
import Html exposing (text)


check : Int -> Bool
check n =
    let
        half =
            n // 2
    in
    Array.initialize n identity
        == Array.append
            (Array.initialize half identity)
            (Array.initialize half (\i -> i + half))


main =
    let
        _ = Debug.log "append32"  (check 32)
        _ = Debug.log "append64"  (check 64)
        _ = Debug.log "append96"  (check 96)
        _ = Debug.log "append128" (check 128)
        _ = Debug.log "append160" (check 160)
        _ = Debug.log "append256" (check 256)
    in
    text "done"
