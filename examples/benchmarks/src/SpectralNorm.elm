module SpectralNorm exposing (bench, output)

{-| Spectral norm: approximate the spectral norm of an infinite matrix `A` (truncated to n x n)
with ten rounds of the power method on `AᵀA`. Float division in nested loops over lists.

The norm of the infinite matrix is 1.274224152821228. The truncated one approaches it from below,
by less than `5 / n^3` at every size (computed with a C program from 1 to 5,500: 0.27 at 1,
4.2e-6 at 100, 4.7e-9 at 1,000), so the result must lie between `limit - 6 / n^3` and `limit`,
give or take 1e-12 of rounding.
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


{-| The norm, computed from an `n` x `n` truncation.
-}
norm : Int -> Float
norm n =
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
    sqrt (vBv / vv)


{-| The benchmark's standard output: the norm with nine decimals.
-}
output : Int -> String
output n =
    Output.fixed9 (norm n) ++ "\n"


limit : Float
limit =
    1.274224152821228


bench : Int -> Bool
bench n =
    let
        x =
            norm n

        f =
            toFloat n
    in
    x <= limit + 1.0e-12 && x >= limit - 6 / (f * f * f) - 1.0e-12
