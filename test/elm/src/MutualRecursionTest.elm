module MutualRecursionTest exposing (main)

{-| Test mutually recursive functions.
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
