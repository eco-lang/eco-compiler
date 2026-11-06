module TypeMismatchTwentyEightTypeVariablesTest exposing (main)

{-| Using a function of 28 unannotated arguments as a number is rejected with a TYPE MISMATCH.

`f` takes 28 arguments `p0` to `p27` and returns `0`; `main = f + 1` gives the function itself to `+`. Each unused argument has its own type variable, so the error message must present a function type with 28 distinct variables.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -


f p0 p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13 p14 p15 p16 p17 p18 p19 p20 p21 p22 p23 p24 p25 p26 p27 =
    0


main =
    f + 1
