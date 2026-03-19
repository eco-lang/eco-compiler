module PolyChainCallTest exposing (main)

{-| Test polymorphic chain callers: polymorphic function calling polymorphic callee multiple times. -}

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
