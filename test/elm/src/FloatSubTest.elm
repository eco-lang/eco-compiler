module FloatSubTest exposing (main)

{-| Float subtraction gives the expected value, including when the right operand is a negative literal.

The cases are `10.0 - 3.0`, `5.0 - -5.0` and `-2.0 - -3.0`.

-}

-- CHECK: sub1: 7
-- CHECK: sub2: 10
-- CHECK: sub3: 1

import Html exposing (text)


main =
    let
        _ = Debug.log "sub1" (10.0 - 3.0)
        _ = Debug.log "sub2" (5.0 - -5.0)
        _ = Debug.log "sub3" (-2.0 - -3.0)
    in
    text "done"
