module BinaryTrees exposing (bench)

{-| Allocation and GC churn: build many short-lived trees of depth 14 and walk them. A tree of
depth 14 has 2^15 - 1 nodes and leaves, which is what each walk must count.
-}


type Tree
    = Leaf
    | Node Tree Tree


build : Int -> Tree
build d =
    if d <= 0 then
        Leaf

    else
        Node (build (d - 1)) (build (d - 1))


check : Tree -> Int
check t =
    case t of
        Leaf ->
            1

        Node l r ->
            1 + check l + check r


run : Int -> Int -> Int
run k acc =
    if k <= 0 then
        acc

    else
        run (k - 1) (acc + check (build 14))


bench : Int -> Bool
bench n =
    run n 0 == n * (2 ^ 15 - 1)
