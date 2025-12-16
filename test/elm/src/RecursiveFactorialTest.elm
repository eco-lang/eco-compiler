module RecursiveFactorialTest exposing (main)

{-| Test simple recursion with factorial.
-}

-- CHECK: fact0: 1
-- CHECK: fact5: 120
-- CHECK: fact10: 3628800

import Html exposing (text)


factorial n =
    if n <= 1 then
        1
    else
        n * factorial (n - 1)


main =
    let
        _ = Debug.log "fact0" (factorial 0)
        _ = Debug.log "fact5" (factorial 5)
        _ = Debug.log "fact10" (factorial 10)
    in
    text "done"
