module Output exposing (checksum, fixed3, fixed9)

{-| Helpers for the workloads that produce the standard text output of their benchmark: a
checksum of that text (the result `bench` returns) and C's `%.9f` float formatting.
-}


{-| A polynomial hash of the text, small enough to stay exact on every backend.
-}
checksum : String -> Int
checksum text =
    String.foldl (\c h -> modBy 1000000007 (h * 31 + Char.toCode c)) 0 text


{-| Format a float with nine decimals, like `printf("%.9f")`.
-}
fixed9 : Float -> String
fixed9 =
    fixed 9 1000000000


{-| Format a float with three decimals, like `printf("%.3f")`.
-}
fixed3 : Float -> String
fixed3 =
    fixed 3 1000


fixed : Int -> Int -> Float -> String
fixed decimals scale x =
    let
        scaled =
            round (x * toFloat scale)

        digits =
            abs scaled
    in
    (if scaled < 0 then
        "-"

     else
        ""
    )
        ++ String.fromInt (digits // scale)
        ++ "."
        ++ String.padLeft decimals '0' (String.fromInt (remainderBy scale digits))
