module SetDistinct exposing (bench)

{-| Distinct values: `Set.fromList` over `n` pseudo-random values drawn from a range of `n / 3`,
so most are duplicates, then `Set.size` and `Set.toList`. Repeated inserts of members already
present.

Checked at every size against an independent count: an `Array Bool` of seen values over a
second, separately generated copy of the sequence, with no `Set`. The distinct count and the
sum of the distinct values must match.

-}

import Array
import Set


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
                acc

            else
                let
                    s =
                        next seed
                in
                go (i - 1) s (modBy range s :: acc)
    in
    go n 1 []


bench : Int -> Bool
bench n =
    let
        distinct =
            Set.fromList (values n)

        seen =
            List.foldl (\v a -> Array.set v True a) (Array.repeat (max 1 (n // 3)) False) (values n)

        ( count, sum ) =
            Array.foldl
                (\present ( i, ( c, s ) ) ->
                    if present then
                        ( i + 1, ( c + 1, s + i ) )

                    else
                        ( i + 1, ( c, s ) )
                )
                ( 0, ( 0, 0 ) )
                seen
                |> Tuple.second
    in
    Set.size distinct == count && List.sum (Set.toList distinct) == sum
