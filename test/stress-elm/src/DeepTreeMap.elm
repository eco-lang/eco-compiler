module DeepTreeMap exposing (main)

-- CHECK: roundtrip: True

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


mapTree : (Int -> Int) -> Tree -> Tree
mapTree f tree =
    case tree of
        Leaf v ->
            Leaf (f v)

        Branch left right ->
            Branch (mapTree f left) (mapTree f right)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildTree 1 m

        transformed =
            applyNTimes n (mapTree negate) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
