module EraseWrapperRecursiveTest exposing (main)

{-| Wrappers on a cycle of wrapper types are not erased (erasing them would
make the type infinite), and still behave: a self-recursive wrapper `type Tree
= Tree (List Tree)`, and two mutually recursive wrappers `type A = A (List B)`
and `type B = B (Maybe A)`. A wrapper whose field holds a non-wrapper type that
refers back to it (`type Expr = Expr ExprNode` with `ExprNode` a custom type of
several constructors) is not a cycle of wrappers and is erased.

-}

-- CHECK: size: 4
-- CHECK: depth: 3
-- CHECK: tree: Tree [Tree [],Tree [Tree []]]
-- CHECK: ab: 2
-- CHECK: expr: 7
-- CHECK: exprShow: Expr (Add (Expr (Lit 3)) (Expr (Lit 4)))

import Html exposing (text)


type Tree
    = Tree (List Tree)


size : Tree -> Int
size (Tree kids) =
    1 + List.sum (List.map size kids)


depth : Tree -> Int
depth (Tree kids) =
    1 + (List.maximum (List.map depth kids) |> Maybe.withDefault 0)


type A
    = A (List B)


type B
    = B (Maybe A)


countA : A -> Int
countA (A bs) =
    1 + List.sum (List.map countB bs)


countB : B -> Int
countB (B ma) =
    case ma of
        Just a ->
            countA a

        Nothing ->
            0


type Expr
    = Expr ExprNode


type ExprNode
    = Lit Int
    | Add Expr Expr


eval : Expr -> Int
eval (Expr node) =
    case node of
        Lit n ->
            n

        Add a b ->
            eval a + eval b


main =
    let
        t =
            Tree [ Tree [], Tree [ Tree [] ] ]

        _ =
            Debug.log "size" (size t)

        _ =
            Debug.log "depth" (depth t)

        _ =
            Debug.log "tree" t

        _ =
            Debug.log "ab" (countA (A [ B (Just (A [])), B Nothing ]))

        e =
            Expr (Add (Expr (Lit 3)) (Expr (Lit 4)))

        _ =
            Debug.log "expr" (eval e)

        _ =
            Debug.log "exprShow" e
    in
    text "done"
