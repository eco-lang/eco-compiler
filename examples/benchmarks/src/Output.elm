module Output exposing (checksum, fixed9)

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
fixed9 x =
    let
        scaled =
            round (x * 1.0e9)

        digits =
            abs scaled
    in
    (if scaled < 0 then
        "-"

     else
        ""
    )
        ++ String.fromInt (digits // 1000000000)
        ++ "."
        ++ String.padLeft 9 '0' (String.fromInt (remainderBy 1000000000 digits))
