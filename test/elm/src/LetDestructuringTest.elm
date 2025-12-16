module LetDestructuringTest exposing (main)

{-| Test pattern destructuring in let.
-}

-- CHECK: first: 1
-- CHECK: second: 2
-- CHECK: head: 10

import Html exposing (text)


main =
    let
        (first, second) = (1, 2)
        (a, b, c) = (10, 20, 30)
        _ = Debug.log "first" first
        _ = Debug.log "second" second
        _ = Debug.log "head" a
    in
    text "done"
