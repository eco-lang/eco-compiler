module FloatNaNOrderTest exposing (main)

{-| The order operators with a NaN operand. Elm's JS generator emits the raw JS operator when
either operand is a number literal, and `_Utils_cmp(a, b) <op> 0` otherwise; `_Utils_cmp` gives
GT whenever a NaN is involved. So `1 > nan` is False (IEEE) but `one > nan`, with `one` a
variable, follows `_Utils_cmp`. elm/core's `max` and `clamp` are Elm functions over variables, so they
follow `_Utils_cmp` too, and eco inlines them into its order operators. Expectations recorded from Elm on node (run-js-e2e.js --record).
-}

-- XFAIL-NATIVE: deliberate divergence from Elm (design_docs/float-semantics.md, CGEN_086): eco's
-- order operators are IEEE whatever the operands, and its max/clamp propagate NaN
-- CHECK: lit 1 < nan: "False"
-- CHECK: lit nan < 1: "False"
-- CHECK: lit 1 > nan: "False"
-- CHECK: lit nan > 1: "False"
-- CHECK: lit 1 <= nan: "False"
-- CHECK: lit nan <= 1: "False"
-- CHECK: lit 1 >= nan: "False"
-- CHECK: lit nan >= 1: "False"
-- CHECK: var one < nan: "False"
-- CHECK: var nan < one: "False"
-- CHECK: var one > nan: "True"
-- CHECK: var nan > one: "True"
-- CHECK: var one <= nan: "False"
-- CHECK: var nan <= one: "False"
-- CHECK: var one >= nan: "True"
-- CHECK: var nan >= one: "True"
-- CHECK: var nan < nan: "False"
-- CHECK: var nan > nan: "True"
-- CHECK: var nan <= nan: "False"
-- CHECK: var nan >= nan: "True"
-- CHECK: max 1 nan: "1"
-- CHECK: max nan 1: "NaN"
-- CHECK: max nan nan: "NaN"
-- CHECK: clamp 0 1 nan: "1"
-- CHECK: foldl max: "1"
-- CHECK: foldl max rev: "NaN"

import ConformanceHelp exposing (logAll, worker)


nan : Float
nan =
    0 / 0


one : Float
one =
    1


show : a -> String
show =
    Debug.toString


report : ()
report =
    logAll
        [ ( "lit 1 < nan", show (1 < nan) )
        , ( "lit nan < 1", show (nan < 1) )
        , ( "lit 1 > nan", show (1 > nan) )
        , ( "lit nan > 1", show (nan > 1) )
        , ( "lit 1 <= nan", show (1 <= nan) )
        , ( "lit nan <= 1", show (nan <= 1) )
        , ( "lit 1 >= nan", show (1 >= nan) )
        , ( "lit nan >= 1", show (nan >= 1) )
        , ( "var one < nan", show (one < nan) )
        , ( "var nan < one", show (nan < one) )
        , ( "var one > nan", show (one > nan) )
        , ( "var nan > one", show (nan > one) )
        , ( "var one <= nan", show (one <= nan) )
        , ( "var nan <= one", show (nan <= one) )
        , ( "var one >= nan", show (one >= nan) )
        , ( "var nan >= one", show (nan >= one) )
        , ( "var nan < nan", show (nan < nan) )
        , ( "var nan > nan", show (nan > nan) )
        , ( "var nan <= nan", show (nan <= nan) )
        , ( "var nan >= nan", show (nan >= nan) )
        , ( "max 1 nan", show (max 1 nan) )
        , ( "max nan 1", show (max nan 1) )
        , ( "max nan nan", show (max nan nan) )
        , ( "clamp 0 1 nan", show (clamp 0 1 nan) )
        , ( "foldl max", show (List.foldl max nan [ 1 ]) )
        , ( "foldl max rev", show (List.foldl max 1 [ nan ]) )
        ]


main : Program () () ()
main =
    worker report
