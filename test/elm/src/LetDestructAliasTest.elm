module LetDestructAliasTest exposing (main)

{-| Test let-destructuring with alias patterns. -}

-- CHECK: pair: (1, 2)
-- CHECK: first: 1

import Html exposing (text)


main =
    let
        (((a, b)) as pair) = (1, 2)
        _ = Debug.log "pair" pair
        _ = Debug.log "first" a
    in
    text "done"
