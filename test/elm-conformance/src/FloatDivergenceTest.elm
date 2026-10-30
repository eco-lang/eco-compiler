module FloatDivergenceTest exposing (main)

{-| Float cases where eco differs from Elm ON PURPOSE (design_docs/float-semantics.md): eco's
`compare` is a total order (NaN equals NaN and is above every number), its `max`/`min` are IEEE
754-2019 (NaN propagates from either argument), and Float-to-Int conversion saturates. The
expectations are Elm's own results, recorded from Elm on node (run-js-e2e.js --record), so the test
passes on node and is an expected failure natively for good: it keeps each difference visible.
eco's own results for these cases are checked by test/elm/src/FloatIeeeSemanticsTest.elm.
-}

-- XFAIL-NATIVE: deliberate divergence from Elm (design_docs/float-semantics.md, CGEN_086)
-- CHECK: min nan 1: "1"
-- CHECK: compare 1 nan: "GT"
-- CHECK: compare nan nan: "GT"
-- CHECK: foldl min rev: "1"
-- CHECK: case compare 1 nan: "GT"
-- CHECK: map2 compare: "GT,GT"
-- CHECK: truncate inf: "0"

import ConformanceHelp exposing (logAll, worker)


nan : Float
nan =
    0 / 0


inf : Float
inf =
    1 / 0


show : a -> String
show =
    Debug.toString


{-| A case on `compare`, which eco rewrites into direct tests (EcoCompareCaseRewrite).
-}
orderName : Float -> Float -> String
orderName a b =
    case compare a b of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


report : ()
report =
    logAll
        [ ( "min nan 1", show (min nan 1) )
        , ( "compare 1 nan", show (compare 1 nan) )
        , ( "compare nan nan", show (compare nan nan) )
        , ( "foldl min rev", show (List.foldl min 1 [ nan ]) )
        , ( "case compare 1 nan", orderName 1 nan )
        , ( "map2 compare", String.join "," (List.map show (List.map2 compare [ nan, 1 ] [ 1, nan ])) )
        , ( "truncate inf", show (truncate inf) )
        ]


main : Program () () ()
main =
    worker report
