module Sort exposing (bench)

{-| Sorting: generate a pseudo-random list, sort it with `List.sort`, then checksum it.
-}


gen : Int -> Int -> List Int -> List Int
gen n seed acc =
    if n <= 0 then
        acc

    else
        let
            -- Park-Miller minstd: seed * 16807 stays under 2^53, so every backend agrees.
            s2 =
                modBy 2147483647 (seed * 16807)
        in
        gen (n - 1) s2 (s2 :: acc)


bench : Int -> Int
bench n =
    gen n 1 []
        |> List.sort
        |> List.foldl (\x a -> modBy 1000000007 (a * 31 + x)) 0
