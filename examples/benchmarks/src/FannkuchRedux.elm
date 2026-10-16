module FannkuchRedux exposing (bench, output)

{-| Fannkuch-redux: for every permutation of `0 .. n-1`, count the pancake flips (reverse the
first `p[0] + 1` elements) until `0` comes first; report the maximum and an alternating-sign
checksum over the permutations in the standard order. Short lists rebuilt constantly.

Both numbers must match `known`, computed for 1 to 12 items by the benchmark's standard C
algorithm; 13 items and more fail the check (13! permutations would take hours).
-}

import Array exposing (Array)


flips : List Int -> Int
flips p =
    case p of
        0 :: _ ->
            0

        first :: _ ->
            1 + flips (List.reverse (List.take (first + 1) p) ++ List.drop (first + 1) p)

        [] ->
            0


{-| Move the first element of the prefix of length `k` to the end of that prefix.
-}
rotate : Int -> List Int -> List Int
rotate k p =
    case p of
        first :: rest ->
            List.take (k - 1) rest ++ first :: List.drop (k - 1) rest

        [] ->
            []


type alias State =
    { p : List Int
    , count : Array Int
    , checksum : Int
    , maxFlips : Int
    }


{-| Advance the permutation counter from position `k` on, rotating as it carries (the `else`
branch of the standard algorithm, after its swap of `p[1]` and `p[2]`).
-}
carry : Int -> List Int -> Array Int -> ( List Int, Array Int )
carry k p count =
    let
        c =
            Maybe.withDefault 0 (Array.get k count) + 1
    in
    if c <= k then
        ( p, Array.set k c count )

    else
        carry (k + 1) (rotate (k + 2) p) (Array.set k 0 count)


loop : Int -> Int -> Bool -> State -> State
loop total idx sign s =
    let
        f =
            flips s.p

        counted =
            { s
                | maxFlips = max s.maxFlips f
                , checksum =
                    if sign then
                        s.checksum + f

                    else
                        s.checksum - f
            }
    in
    if idx + 1 == total then
        counted

    else if sign then
        case s.p of
            x :: y :: rest ->
                loop total (idx + 1) False { counted | p = y :: x :: rest }

            _ ->
                counted

    else
        case s.p of
            x :: y :: z :: rest ->
                let
                    ( p2, count2 ) =
                        carry 2 (x :: z :: y :: rest) s.count
                in
                loop total (idx + 1) True { counted | p = p2, count = count2 }

            _ ->
                counted


{-| The checksum and the maximum number of flips over every permutation of `n` items.
-}
run : Int -> ( Int, Int )
run n =
    let
        total =
            List.product (List.range 1 n)

        s =
            loop total 0 True (State (List.range 0 (n - 1)) (Array.repeat (n + 1) 0) 0 0)
    in
    ( s.checksum, s.maxFlips )


{-| The benchmark's standard output: the checksum and the maximum number of flips.
-}
output : Int -> String
output n =
    let
        ( checksum, maxFlips ) =
            run n
    in
    String.fromInt checksum ++ "\nPfannkuchen(" ++ String.fromInt n ++ ") = " ++ String.fromInt maxFlips ++ "\n"


{-| `( checksum, maximum flips )` for 1 to 12 items.
-}
known : List ( Int, Int )
known =
    [ ( 0, 0 ), ( -1, 1 ), ( 2, 2 ), ( 4, 4 ), ( 11, 7 ), ( 49, 10 ), ( 228, 16 ), ( 1616, 22 ), ( 8629, 30 ), ( 73196, 38 ), ( 556355, 51 ), ( 3968050, 65 ) ]


bench : Int -> Bool
bench n =
    n >= 1 && List.head (List.drop (n - 1) known) == Just (run n)
