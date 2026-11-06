module MutualRecursionTest exposing (main)

{-| Two top-level functions that call each other, `isEven` and `isOdd`, decide parity by counting down to zero.

`isEven 0` is `True`, `isEven 5` is `False` and `isOdd 5` is `True`.
-}

-- CHECK: isEven0: True
-- CHECK: isEven5: False
-- CHECK: isOdd5: True

import Html exposing (text)


isEven n =
    if n == 0 then
        True
    else
        isOdd (n - 1)


isOdd n =
    if n == 0 then
        False
    else
        isEven (n - 1)


main =
    let
        _ = Debug.log "isEven0" (isEven 0)
        _ = Debug.log "isEven5" (isEven 5)
        _ = Debug.log "isOdd5" (isOdd 5)
    in
    text "done"
