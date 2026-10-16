module FloatSum exposing (bench)

{-| Float lists: build a `List Float`, map an affine transform over it, then fold a sum of
squares. The exact sum of `(1.5 i + 0.5)^2` over `1 .. n` is
`2.25 n (n + 1) (2n + 1) / 6 + 1.5 n (n + 1) / 2 + 0.25 n`; the folded sum must be within its
rounding error of that, `n` units in the last place.
-}


bench : Int -> Bool
bench n =
    let
        xs =
            List.map (\i -> toFloat i) (List.range 1 n)

        scaled =
            List.map (\x -> x * 1.5 + 0.5) xs

        sum =
            List.foldl (\x acc -> acc + x * x) 0.0 scaled

        f =
            toFloat n

        exact =
            2.25 * f * (f + 1) * (2 * f + 1) / 6 + 1.5 * f * (f + 1) / 2 + 0.25 * f
    in
    abs (sum - exact) <= exact * f * 2.3e-16
