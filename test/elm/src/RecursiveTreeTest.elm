module RecursiveTreeTest exposing (main)

{-| Test recursive binary tree type with sum and depth traversals. -}

-- CHECK: sum: 6
-- CHECK: depth: 3

import Html exposing (text)


type Tree a
    = Leaf a
    | Branch (Tree a) (Tree a)


sumTree tree =
    case tree of
        Leaf n -> n
        Branch left right -> sumTree left + sumTree right


depth tree =
    case tree of
        Leaf _ -> 1
        Branch left right ->
            1 + max (depth left) (depth right)


main =
    let
        t = Branch (Branch (Leaf 1) (Leaf 2)) (Leaf 3)
        _ = Debug.log "sum" (sumTree t)
        _ = Debug.log "depth" (depth t)
    in
    text "done"
