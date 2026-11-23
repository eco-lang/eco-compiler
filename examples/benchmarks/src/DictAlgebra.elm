module DictAlgebra exposing (bench, benchUnionSmall)

{-| Dict set algebra: `Dict.union`, `intersect`, `diff` and `merge` on two large dicts whose keys
overlap in a known way (multiples of 2 and multiples of 3 below `n`), repeated three times with
the values shifted. Each operation rebuilds a whole tree, so this measures `Dict`'s bulk
operations rather than single inserts.

Checked at every size in closed form: the sizes are the counts of multiples of 2, of 3, of 6 and
of 2 but not 3, and every value sum is a sum over an arithmetic progression.

-}

import Dict exposing (Dict)


{-| The multiples of `step` below `n`, each mapped to `k * shift`.
-}
multiples : Int -> Int -> Int -> Dict Int Int
multiples step shift n =
    Dict.fromList (List.map (\k -> ( k, k * shift )) (List.range 0 ((n - 1) // step) |> List.map (\i -> i * step)))


{-| Count and sum of the multiples of `step` below `n`.
-}
progression : Int -> Int -> ( Int, Int )
progression step n =
    let
        count =
            (n - 1) // step + 1

        -- 0 + step + ... + (count - 1) * step, with the even factor halved first (see ListFold)
        sum =
            if modBy 2 count == 0 then
                step * (count // 2) * (count - 1)

            else
                step * count * ((count - 1) // 2)
    in
    ( count, sum )


valueSum : Dict Int Int -> Int
valueSum d =
    Dict.foldl (\_ v s -> s + v) 0 d


pass : Int -> Int -> Bool
pass n shift =
    let
        twos =
            multiples 2 shift n

        threes =
            multiples 3 (shift + 1) n

        ( c2, s2 ) =
            progression 2 n

        ( c3, s3 ) =
            progression 3 n

        ( c6, s6 ) =
            progression 6 n

        union =
            Dict.union twos threes

        inter =
            Dict.intersect twos threes

        diff =
            Dict.diff twos threes

        -- keys in both get the sum of their values; keys in one keep theirs
        merged =
            Dict.merge
                (\k v acc -> Dict.insert k v acc)
                (\k a b acc -> Dict.insert k (a + b) acc)
                (\k v acc -> Dict.insert k v acc)
                twos
                threes
                Dict.empty
    in
    -- union prefers the first dict's values; intersect keeps the first's values for keys in both
    (Dict.size union == c2 + c3 - c6)
        && (valueSum union == shift * s2 + (shift + 1) * (s3 - s6))
        && (Dict.size inter == c6)
        && (valueSum inter == shift * s6)
        && (Dict.size diff == c2 - c6)
        && (valueSum diff == shift * (s2 - s6))
        && (Dict.size merged == c2 + c3 - c6)
        && (valueSum merged == shift * s2 + (shift + 1) * s3)


bench : Int -> Bool
bench n =
    List.all (pass n) [ 1, 2, 3 ]


{-| `union` of 64 small dicts (each `n / 64` keys, disjoint from the large one) into one large dict of `n`
keys, and `diff` of the large dict and 64 small dicts of keys it holds: the shape `insert`ing a few keys
into a big map takes, where a rebuild of the whole result would cost the big map's size every time.
Checked in closed form: every result's size, and lookups of its first, last and boundary keys.
-}
benchUnionSmall : Int -> Bool
benchUnionSmall n =
    let
        m =
            max 1 (n // 64)

        big =
            Dict.fromList (List.map (\k -> ( k, k )) (List.range 0 (n - 1)))

        round r ok =
            let
                outside =
                    Dict.fromList (List.map (\k -> ( k, 2 * k )) (List.range (n + r * m) (n + r * m + m - 1)))

                inside =
                    Dict.fromList (List.map (\k -> ( k, 2 * k )) (List.range (modBy n (r * m)) (modBy n (r * m) + m - 1)))

                unioned =
                    Dict.union outside big

                diffed =
                    Dict.diff big inside

                lo =
                    modBy n (r * m)

                insideCount =
                    min m (n - lo)
            in
            ok
                && (Dict.size unioned == n + m)
                && (Dict.get (n + r * m) unioned == Just (2 * (n + r * m)))
                && (Dict.get (n + r * m + m - 1) unioned == Just (2 * (n + r * m + m - 1)))
                && (Dict.get (n - 1) unioned == Just (n - 1))
                && (Dict.size diffed == n - insideCount)
                && (Dict.get lo diffed == Nothing)
                && (lo + m >= n || Dict.get (lo + m) diffed == Just (lo + m))
    in
    List.foldl round True (List.range 0 63)
