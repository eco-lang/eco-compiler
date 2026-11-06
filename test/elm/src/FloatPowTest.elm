module FloatPowTest exposing (main)

{-| `^` on Floats computes powers with positive, zero and negative exponents.

`2.0 ^ 3.0` is 8, `5.0 ^ 0.0` is 1, `2.0 ^ 10.0` is 1024 and `2.0 ^ -1.0` is 0.5.

-}

-- CHECK: pow1: 8
-- CHECK: pow2: 1
-- CHECK: pow3: 1024
-- CHECK: pow4: 0.5

import Html exposing (text)


main =
    let
        _ = Debug.log "pow1" (2.0 ^ 3.0)
        _ = Debug.log "pow2" (5.0 ^ 0.0)
        _ = Debug.log "pow3" (2.0 ^ 10.0)
        _ = Debug.log "pow4" (2.0 ^ -1.0)
    in
    text "done"
