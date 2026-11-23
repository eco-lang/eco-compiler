module SeqSetOps exposing (benchAlgebra, benchDistinct, benchUnionSmall)

{-| `SetDistinct`'s and `SetAlgebra`'s workloads on eco/system's `SeqSet`, a `SeqDict a Bool`
underneath, at the same sizes so that each seqset-* figure can be read against its set-* twin.

  - `benchDistinct` (seqset-distinct): `SeqSet.fromList` over `n` pseudo-random values drawn from
    a range of `n / 3`, so most inserts find the member already present, then `size` and
    `toList`. Checked as set-distinct is, against an `Array Bool` of seen values over a second
    copy of the sequence; the members must also come out in first-seen order, checked against
    an `Array Int` of each value's first position.
  - `benchAlgebra` (seqset-algebra): `union`, `intersect`, `diff` and `filter` on the multiples of
    2 and of 3 below `n`, three times. Checked in closed form, as set-algebra is.

-}

import Array
import SeqSet exposing (SeqSet)



-- DISTINCT


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


values : Int -> List Int
values n =
    let
        range =
            max 1 (n // 3)

        go i seed acc =
            if i <= 0 then
                List.reverse acc

            else
                let
                    s =
                        next seed
                in
                go (i - 1) s (modBy range s :: acc)
    in
    go n 1 []


benchDistinct : Int -> Bool
benchDistinct n =
    let
        range =
            max 1 (n // 3)

        distinct =
            SeqSet.fromList (values n)

        -- each value's first position in the sequence, or -1
        firstSeen =
            List.foldl
                (\v ( i, a ) ->
                    if Array.get v a == Just -1 then
                        ( i + 1, Array.set v i a )

                    else
                        ( i + 1, a )
                )
                ( 0, Array.repeat range -1 )
                (values n)
                |> Tuple.second

        ( count, sum ) =
            Array.foldl
                (\first ( i, ( c, s ) ) ->
                    if first >= 0 then
                        ( i + 1, ( c + 1, s + i ) )

                    else
                        ( i + 1, ( c, s ) )
                )
                ( 0, ( 0, 0 ) )
                firstSeen
                |> Tuple.second

        members =
            SeqSet.toList distinct

        -- first positions must rise along the members
        ( _, ordered ) =
            List.foldl
                (\v ( prev, ok ) ->
                    let
                        first =
                            Maybe.withDefault -1 (Array.get v firstSeen)
                    in
                    ( first, ok && first > prev )
                )
                ( -1, True )
                members
    in
    (SeqSet.size distinct == count) && (List.sum members == sum) && ordered



-- ALGEBRA


multiples : Int -> Int -> SeqSet Int
multiples step n =
    SeqSet.fromList (List.map (\i -> i * step) (List.range 0 ((n - 1) // step)))


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


total : SeqSet Int -> Int
total s =
    SeqSet.foldl (+) 0 s


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
            SeqSet.union twos threes

        inter =
            SeqSet.intersect twos threes

        diff =
            SeqSet.diff twos threes

        fours =
            SeqSet.filter (\x -> modBy 4 x == 0) twos
    in
    (SeqSet.size union == c2 + c3 - c6)
        && (total union == s2 + s3 - s6)
        && (SeqSet.size inter == c6)
        && (total inter == s6)
        && (SeqSet.size diff == c2 - c6)
        && (total diff == s2 - s6)
        && (SeqSet.size fours == c4)
        && (total fours == s4)


benchAlgebra : Int -> Bool
benchAlgebra n =
    List.all (pass n) [ 1, 2, 3 ]



-- UNION SMALL


{-| seqdict-union-small's work on SeqSet: `union` of 64 small sets (`n / 64` members, disjoint from
the large one) into a large set of `n` members, and `diff` of the large set and 64 small sets of its
members. Checked by sizes and membership of the boundary members.
-}
benchUnionSmall : Int -> Bool
benchUnionSmall n =
    let
        m =
            max 1 (n // 64)

        big =
            SeqSet.fromList (List.range 0 (n - 1))

        round r ok =
            let
                lo =
                    modBy n (r * m)

                insideCount =
                    min m (n - lo)

                unioned =
                    SeqSet.union (SeqSet.fromList (List.range (n + r * m) (n + r * m + m - 1))) big

                diffed =
                    SeqSet.diff big (SeqSet.fromList (List.range lo (lo + m - 1)))
            in
            ok
                && (SeqSet.size unioned == n + m)
                && SeqSet.member (n + r * m) unioned
                && SeqSet.member (n - 1) unioned
                && (SeqSet.size diffed == n - insideCount)
                && not (SeqSet.member lo diffed)
                && (lo + m >= n || SeqSet.member (lo + m) diffed)
    in
    List.foldl round True (List.range 0 63)
