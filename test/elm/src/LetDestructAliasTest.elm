module LetDestructAliasTest exposing (main)

{-| A `let` destructuring with an `as` pattern binds both the parts and the whole: from
`((a, b)) as pair = (1, 2)`, `pair` is `(1,2)` and `a` is 1.
-}

-- CHECK: pair: (1,2)
-- CHECK: first: 1

import Html exposing (text)


main =
    let
        (((a, b)) as pair) = (1, 2)
        _ = Debug.log "pair" pair
        _ = Debug.log "first" a
    in
    text "done"
