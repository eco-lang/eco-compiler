module TreeBuildFold exposing (main)

-- CHECK: result: 500500000

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


type Tree
    = Leaf Int
    | Branch Tree Tree


buildTree : Int -> Int -> Tree
buildTree lo hi =
    if lo >= hi then
        Leaf lo
    else
        let
            mid =
                (lo + hi) // 2
        in
        Branch (buildTree lo mid) (buildTree (mid + 1) hi)


foldTree : (Int -> a -> a) -> a -> Tree -> a
foldTree f acc tree =
    case tree of
        Leaf v ->
            f v acc

        Branch left right ->
            foldTree f (foldTree f acc left) right


loop : Int -> Int -> Int
loop count acc =
    if count <= 0 then
        acc
    else
        let
            tree =
                buildTree 1 m

            sum =
                foldTree (+) 0 tree
        in
        loop (count - 1) (acc + sum)


main =
    let
        -- Each tree fold sums 1..m = m*(m+1)/2 = 500500
        -- After n iterations: n * 500500 = 500500000
        result =
            loop n 0

        _ =
            Debug.log "result" result
    in
    text "done"
