module Mandelbrot exposing (bench)

{-| Float arithmetic, no allocation: count the points of an N x N grid that stay inside the
Mandelbrot set for 100 iterations.

The count has no closed form. At the sizes in `known` (computed by a C program doing the same
arithmetic in the same order) it must match exactly; at other sizes of 50 and up it must be a
plausible share of the grid, 16.5-18 %: the set's area is about 1.506 of the 9 the grid covers,
and the points that escape only after 100 iterations add a little. Below 50 an unknown size is
not checked.
-}


maxIter : Int
maxIter =
    100


iter : Float -> Float -> Float -> Float -> Int -> Int
iter zr zi cr ci n =
    if n >= maxIter then
        1

    else if zr * zr + zi * zi > 4.0 then
        0

    else
        iter (zr * zr - zi * zi + cr) (2.0 * zr * zi + ci) cr ci (n + 1)


row : Int -> Int -> Int -> Int -> Int
row size y x acc =
    if x >= size then
        acc

    else
        let
            cr =
                (toFloat x / toFloat size) * 3.0 - 2.0

            ci =
                (toFloat y / toFloat size) * 3.0 - 1.5
        in
        row size y (x + 1) (acc + iter 0.0 0.0 cr ci 0)


grid : Int -> Int -> Int -> Int
grid size y acc =
    if y >= size then
        acc

    else
        grid size (y + 1) (row size y 0 acc)


known : List ( Int, Int )
known =
    [ ( 1, 0 ), ( 2, 2 ), ( 3, 2 ), ( 10, 20 ), ( 50, 432 ), ( 100, 1754 ), ( 200, 6911 ), ( 400, 27551 ), ( 800, 110151 ), ( 1000, 172031 ), ( 2200, 832253 ) ]


bench : Int -> Bool
bench size =
    let
        count =
            grid size 0 0

        share =
            toFloat count / toFloat (size * size)
    in
    case List.filter (\( s, _ ) -> s == size) known of
        ( _, expected ) :: _ ->
            count == expected

        [] ->
            size < 50 || (share >= 0.165 && share <= 0.18)
