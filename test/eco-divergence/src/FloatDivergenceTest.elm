module FloatDivergenceTest exposing (main)

{-| Float cases where eco differs from Elm ON PURPOSE (design_docs/float-semantics.md): eco's
`compare` is a total order (NaN equals NaN and is above every number), its `max`/`min` are IEEE
754-2019 (NaN propagates from either argument), and Float-to-Int conversion saturates. The CHECK lines are
eco's results and the `-- ELM:` lines Elm's, recorded on node (run-js-e2e.js --record), so each
difference stays visible. FloatIeeeSemanticsTest, in this suite, checks more of eco's results.
-}

-- DIVERGENCE: deliberate divergence from Elm (design_docs/float-semantics.md, CGEN_086)
-- CHECK: min nan 1: "NaN"
-- CHECK: compare 1 nan: "LT"
-- CHECK: compare nan nan: "EQ"
-- CHECK: foldl min rev: "NaN"
-- CHECK: case compare 1 nan: "LT"
-- CHECK: map2 compare: "GT,LT"
-- CHECK: truncate inf: "9223372036854775807"
-- ELM: min nan 1: "1"
-- ELM: compare 1 nan: "GT"
-- ELM: compare nan nan: "GT"
-- ELM: foldl min rev: "1"
-- ELM: case compare 1 nan: "GT"
-- ELM: map2 compare: "GT,GT"
-- ELM: truncate inf: "0"

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
