module Sort exposing (bench)

{-| Sorting: generate a pseudo-random list and sort it with `List.sort`. The result must be in
order, as long as the input, and hold the same values: two sums over its elements must match the
same sums over the generated sequence, regenerated without a list.
-}


{-| Park-Miller minstd: `seed * 16807` stays under 2^53, so every backend agrees.
-}
next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


gen : Int -> Int -> List Int -> List Int
gen n seed acc =
    if n <= 0 then
        acc

    else
        let
            s2 =
                next seed
        in
        gen (n - 1) s2 (s2 :: acc)


{-| Two sums over the elements, kept under 2^53 at every step: the values, and the squares of
the values modulo 1000003.
-}
addSum : Int -> Int -> Int
addSum x sum =
    modBy 1000000007 (sum + x)


addSquare : Int -> Int -> Int
addSquare x squares =
    let
        r =
            modBy 1000003 x
    in
    modBy 1000000007 (squares + r * r)


{-| Count and sums of the generated sequence, without building it.
-}
generated : Int -> Int -> Int -> Int -> Int -> ( Int, Int, Int )
generated n seed count sum squares =
    if n <= 0 then
        ( count, sum, squares )

    else
        let
            s2 =
                next seed
        in
        generated (n - 1) s2 (count + 1) (addSum s2 sum) (addSquare s2 squares)


{-| Count and sums of a list, or `Nothing` if it is out of order.
-}
sorted : Int -> List Int -> Int -> Int -> Int -> Maybe ( Int, Int, Int )
sorted previous xs count sum squares =
    case xs of
        [] ->
            Just ( count, sum, squares )

        x :: rest ->
            if x < previous then
                Nothing

            else
                sorted x rest (count + 1) (addSum x sum) (addSquare x squares)


bench : Int -> Bool
bench n =
    sorted 0 (List.sort (gen n 1 [])) 0 0 0 == Just (generated n 1 0 0 0)
