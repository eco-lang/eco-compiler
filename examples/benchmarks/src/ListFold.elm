module ListFold exposing (bench)

{-| List traversal: build a range and fold it to a number, with no other allocation.
-}


bench : Int -> Int
bench n =
    List.range 1 n
        |> List.foldl (\x a -> modBy 1000000007 (a + x)) 0
