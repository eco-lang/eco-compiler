module SpectralNorm exposing (bench, output)

{-| Spectral norm: approximate the spectral norm of an infinite matrix `A` (truncated to n x n)
with ten rounds of the power method on `AᵀA`. Float division in nested loops over lists.
-}

import Output


{-| Entry `(i, j)` of `A` is `1 / a i j`.
-}
a : Int -> Int -> Int
a i j =
    (i + j) * (i + j + 1) // 2 + i + 1


{-| Row `i` of `A u`, or of `Aᵀ u` when `transpose` is set.
-}
rowSum : Bool -> List Float -> Int -> Float
rowSum transpose u i =
    let
        go j us acc =
            case us of
                [] ->
                    acc

                uj :: rest ->
                    let
                        d =
                            if transpose then
                                a j i

                            else
                                a i j
                    in
                    go (j + 1) rest (acc + uj / toFloat d)
    in
    go 0 u 0


multiplyAtAv : List Int -> List Float -> List Float
multiplyAtAv indices u =
    let
        tmp =
            List.map (rowSum False u) indices
    in
    List.map (rowSum True tmp) indices


powerMethod : List Int -> Int -> List Float -> ( List Float, List Float )
powerMethod indices rounds u =
    let
        v =
            multiplyAtAv indices u

        u2 =
            multiplyAtAv indices v
    in
    if rounds <= 1 then
        ( u2, v )

    else
        powerMethod indices (rounds - 1) u2


{-| The benchmark's standard output: the norm with nine decimals.
-}
output : Int -> String
output n =
    let
        indices =
            List.range 0 (n - 1)

        ( u, v ) =
            powerMethod indices 10 (List.repeat n 1)

        vBv =
            List.foldl (+) 0 (List.map2 (*) u v)

        vv =
            List.foldl (+) 0 (List.map2 (*) v v)
    in
    Output.fixed9 (sqrt (vBv / vv)) ++ "\n"


bench : Int -> Int
bench n =
    Output.checksum (output n)
