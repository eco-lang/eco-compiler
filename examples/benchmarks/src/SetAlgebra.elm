module SetAlgebra exposing (bench)

{-| Set algebra: `Set.union`, `intersect`, `diff` and `filter` on two large sets whose members
overlap in a known way (multiples of 2 and multiples of 3 below `n`), repeated three times. Each
operation rebuilds a whole tree, so this measures `Set`'s bulk operations.

Checked at every size in closed form: the sizes are counts of multiples, and every member sum is
a sum over an arithmetic progression.

-}

import Set exposing (Set)


multiples : Int -> Int -> Set Int
multiples step n =
    Set.fromList (List.map (\i -> i * step) (List.range 0 ((n - 1) // step)))


{-| Count and sum of the multiples of `step` below `n`.
-}
progression : Int -> Int -> ( Int, Int )
progression step n =
    let
        count =
            (n - 1) // step + 1

        sum =
            if modBy 2 count == 0 then
                step * (count // 2) * (count - 1)

            else
                step * count * ((count - 1) // 2)
    in
    ( count, sum )


total : Set Int -> Int
total s =
    Set.foldl (+) 0 s


pass : Int -> Int -> Bool
pass n _ =
    let
        twos =
            multiples 2 n

        threes =
            multiples 3 n

        ( c2, s2 ) =
            progression 2 n

        ( c3, s3 ) =
            progression 3 n

        ( c6, s6 ) =
            progression 6 n

        ( c4, s4 ) =
            progression 4 n

        union =
            Set.union twos threes

        inter =
            Set.intersect twos threes

        diff =
            Set.diff twos threes

        fours =
            Set.filter (\x -> modBy 4 x == 0) twos
    in
    (Set.size union == c2 + c3 - c6)
        && (total union == s2 + s3 - s6)
        && (Set.size inter == c6)
        && (total inter == s6)
        && (Set.size diff == c2 - c6)
        && (total diff == s2 - s6)
        && (Set.size fours == c4)
        && (total fours == s4)


bench : Int -> Bool
bench n =
    List.all (pass n) [ 1, 2, 3 ]
