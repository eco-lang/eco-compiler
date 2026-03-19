module MutualRecursionThreeWayTest exposing (main)

{-| Test three-way mutual recursion: funcA calls funcB, funcB calls funcC, funcC calls funcA. -}

-- CHECK: a10: 1
-- CHECK: a9: 0
-- CHECK: a3: 0
-- CHECK: a0: 0

import Html exposing (text)


funcA n =
    if n <= 0 then
        0
    else
        funcB (n - 1)


funcB n =
    if n <= 0 then
        1
    else
        funcC (n - 1)


funcC n =
    if n <= 0 then
        2
    else
        funcA (n - 1)


main =
    let
        _ = Debug.log "a10" (funcA 10)
        _ = Debug.log "a9" (funcA 9)
        _ = Debug.log "a3" (funcA 3)
        _ = Debug.log "a0" (funcA 0)
    in
    text "done"
