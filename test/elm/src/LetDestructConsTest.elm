module LetDestructConsTest exposing (main)

{-| Test cons/list pattern destructuring in let bindings. -}

-- CHECK: head: 1
-- CHECK: second: 20

import Html exposing (text)


main =
    let
        h :: t = [1, 2, 3]
        a :: b :: rest = [10, 20, 30]
        _ = Debug.log "head" h
        _ = Debug.log "second" b
    in
    text "done"
