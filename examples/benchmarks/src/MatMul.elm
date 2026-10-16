module MatMul exposing (bench)

{-| Matrix multiplication (plb2, kostya/benchmarks): two `n` x `n` matrices of Floats built with
plb2's generator, `a[i][j] = (i - j) * (i + j) / n^2`, held as `Array (Array Float)`, multiplied
row by column (the second matrix transposed first, so both are read along rows). `Array.get` in
a triple loop.

`a[i][k] * a[k][j]` sums in closed form: with `t = 1 / n^2`, `S2` the sum of `k^2` and `S4` the
sum of `k^4` over `0 .. n-1`, `c[i][j] = t^2 (i^2 S2 - i^2 j^2 n - S4 + j^2 S2)`. Every element
of the product must be within rounding of that, at every size.

-}

import Array exposing (Array)


matrix : Int -> Array (Array Float)
matrix n =
    let
        t =
            1 / toFloat n / toFloat n
    in
    Array.initialize n (\i -> Array.initialize n (\j -> toFloat (i - j) * toFloat (i + j) * t))


transpose : Int -> Array (Array Float) -> Array (Array Float)
transpose n m =
    Array.initialize n (\j -> Array.map (\r -> Maybe.withDefault 0 (Array.get j r)) m)


dot : Int -> Array Float -> Array Float -> Float
dot n a b =
    let
        go k acc =
            if k >= n then
                acc

            else
                go (k + 1) (acc + Maybe.withDefault 0 (Array.get k a) * Maybe.withDefault 0 (Array.get k b))
    in
    go 0 0


multiply : Int -> Array (Array Float) -> Array (Array Float) -> Array (Array Float)
multiply n a b =
    let
        bt =
            transpose n b
    in
    Array.map (\r -> Array.map (\c -> dot n r c) bt) a


bench : Int -> Bool
bench n =
    let
        a =
            matrix n

        c =
            multiply n a a

        f =
            toFloat n

        t =
            1 / f / f

        s2 =
            (f - 1) * f * (2 * f - 1) / 6

        s4 =
            (f - 1) * f * (2 * f - 1) * (3 * (f - 1) * (f - 1) + 3 * (f - 1) - 1) / 30

        exact i j =
            let
                i2 =
                    toFloat (i * i)

                j2 =
                    toFloat (j * j)
            in
            t * t * (i2 * s2 - i2 * j2 * f - s4 + j2 * s2)

        -- every term of the sum is at most 1 in size, so the rounding error stays below n units
        -- in the last place of 1
        close i j x =
            abs (x - exact i j) <= f * 1.0e-15

        rowOk i r =
            List.all identity (List.indexedMap (\j x -> close i j x) (Array.toList r))
    in
    List.all identity (List.indexedMap rowOk (Array.toList c))
