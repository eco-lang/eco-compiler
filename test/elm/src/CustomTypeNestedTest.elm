module CustomTypeNestedTest exposing (main)

{-| A value of a recursive, parameterised custom type (a binary tree with values
in its leaves) can be built several levels deep and logged.

The only check is that a line starting with `nested` is printed; the logged
text itself is not checked.

-}

-- CHECK: nested

import Html exposing (text)


type Tree a
    = Leaf a
    | Node (Tree a) (Tree a)


main =
    let
        tree = Node (Leaf 1) (Node (Leaf 2) (Leaf 3))
        _ = Debug.log "nested" tree
    in
    text "done"
