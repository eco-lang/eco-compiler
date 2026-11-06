module PolyChainCallTest exposing (main)

{-| Tests a polymorphic function that calls another polymorphic function twice,
building a binary tree of two nodes that is then counted.

`insertTree` makes a new node with the given tree as its left child, so
`buildTree 1 2` is a node holding 2 whose left child holds 1, and `sizeTree`
counts 2 nodes.

-}

-- CHECK: size: 2

import Html exposing (text)


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


insertTree : a -> Tree a -> Tree a
insertTree val tree =
    Node tree val Leaf


buildTree : a -> a -> Tree a
buildTree x y =
    let
        t1 =
            insertTree x Leaf

        t2 =
            insertTree y t1
    in
    t2


sizeTree : Tree a -> Int
sizeTree t =
    case t of
        Leaf ->
            0

        Node left _ right ->
            1 + sizeTree left + sizeTree right


main =
    let
        _ =
            Debug.log "size" (sizeTree (buildTree 1 2))
    in
    text "done"
