module ListOrigin exposing (benchMap, benchTake)

{-| Walk a `List Float` with a hand-written recursive dot product, `n` times. Two workloads do
the same work on equal lists that were built differently:

  - `list-walk-map` walks a list made by `List.map`.
  - `list-walk-take` walks an equal list made by `List.take 384 (plain ++ [ 0, 0 ])`.

On eco a list from `List.take` has been measured 4 to 12 times slower to walk than one from
`List.map` (`eco-bugs.md`, number 6), so the ratio between the two workloads is the thing to
watch. The official Elm compiler treats the two lists alike.

Every element is a small whole number, so each dot product is exact and the running total after
`n` walks must equal `n` times the dot product computed with `Int`s, at every size.

-}


width : Int
width =
    384


plainOf : Int -> Float
plainOf i =
    toFloat (modBy 5 i)


vectorOf : Int -> Float
vectorOf i =
    toFloat (modBy 7 i)


plain : List Float
plain =
    List.map plainOf (List.range 0 (width - 1))


vector : List Float
vector =
    List.map vectorOf (List.range 0 (width - 1))


dot : List Float -> List Float -> Float -> Float
dot xs ys acc =
    case xs of
        x :: xr ->
            case ys of
                y :: yr ->
                    dot xr yr (acc + x * y)

                [] ->
                    acc

        [] ->
            acc


repeat : Int -> List Float -> Float -> Float
repeat left xs acc =
    if left <= 0 then
        acc

    else
        repeat (left - 1) xs (dot xs vector acc)


expected : Int -> Float
expected n =
    toFloat n
        * toFloat
            (List.sum (List.map (\i -> modBy 5 i * modBy 7 i) (List.range 0 (width - 1))))


run : List Float -> Int -> Bool
run xs n =
    List.length xs == width && repeat n xs 0 == expected n


benchMap : Int -> Bool
benchMap n =
    run (List.map plainOf (List.range 0 (width - 1))) n


benchTake : Int -> Bool
benchTake n =
    run (List.take width (plain ++ [ 0, 0 ])) n
