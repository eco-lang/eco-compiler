module ArrayAppendCanonicalTest exposing (main)

{-| `Array.append` must produce a canonical RRB shape so that the result
    compares equal to an `Array.initialize` of the same elements. Sizes
    that are non-power-of-two multiples of the branch factor (32) — e.g.
    96 and 160 — have been observed to diverge.
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
