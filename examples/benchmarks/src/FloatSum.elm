module FloatSum exposing (bench)

{-| Float lists: build a `List Float`, map an affine transform over it, then fold a sum of
squares.
-}


bench : Int -> Int
bench n =
    let
        xs =
            List.map (\i -> toFloat i) (List.range 1 n)

        scaled =
            List.map (\x -> x * 1.5 + 0.5) xs
    in
    round (List.foldl (\x acc -> acc + x * x) 0.0 scaled)
