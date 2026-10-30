module FloatEdgeTest exposing (main)

{-| Float edge cases where native lowering can differ from Elm on node: round's ties, NaN with
equality, min/max and compare, truncate of NaN and infinity, a Float inside Just, and an Int power
past 2^32. Each value is shown with Debug.toString. Expectations recorded from Elm on node
(run-js-e2e.js --record). Every row here can match natively; the ones that cannot, because Int is
i64, are in FloatToIntRangeTest.
-}

-- CHECK: round 2.5: "3"
-- CHECK: round -2.5: "-2"
-- CHECK: round 0.5: "1"
-- CHECK: round -0.5: "0"
-- CHECK: round 1.5: "2"
-- CHECK: round -1.5: "-1"
-- CHECK: nan == nan: "False"
-- CHECK: nan /= nan: "True"
-- CHECK: 1 /= nan: "True"
-- CHECK: min 1 nan: "NaN"
-- CHECK: compare nan 1: "GT"
-- CHECK: foldl min: "NaN"
-- CHECK: map round: "-2,0,3"
-- CHECK: case compare nan 1: "GT"
-- CHECK: case compare 1 2: "LT"
-- CHECK: case compare 2 2: "EQ"
-- CHECK: compare tuple nan: "GT"
-- CHECK: compare list nan: "GT"
-- CHECK: just nan == just nan: "False"
-- CHECK: list nan /= list nan: "True"
-- CHECK: truncate nan: "0"
-- CHECK: toFloat just: "Just 1.5"
-- CHECK: toFloat just eq: "True"
-- CHECK: pow 3 33: "5559060566555523"


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
        [ ( "round 2.5", show (round 2.5) )
        , ( "round -2.5", show (round -2.5) )
        , ( "round 0.5", show (round 0.5) )
        , ( "round -0.5", show (round -0.5) )
        , ( "round 1.5", show (round 1.5) )
        , ( "round -1.5", show (round -1.5) )
        , ( "nan == nan", show (nan == nan) )
        , ( "nan /= nan", show (nan /= nan) )
        , ( "1 /= nan", show (1 /= nan) )
        , ( "min 1 nan", show (min 1 nan) )
        , ( "compare nan 1", show (compare nan 1) )
        , ( "foldl min", show (List.foldl min nan [ 1 ]) )
        , ( "map round", String.join "," (List.map (round >> String.fromInt) [ -2.5, -0.5, 2.5 ]) )
        , ( "case compare nan 1", orderName nan 1 )
        , ( "case compare 1 2", orderName 1 2 )
        , ( "case compare 2 2", orderName 2 2 )
        , ( "compare tuple nan", show (compare ( nan, 1 ) ( 1, 1 )) )
        , ( "compare list nan", show (compare [ nan ] [ 1 ]) )
        , ( "just nan == just nan", show (Just nan == Just nan) )
        , ( "list nan /= list nan", show ([ nan ] /= [ nan ]) )
        , ( "truncate nan", show (truncate nan) )
        , ( "toFloat just", show (String.toFloat "1.5") )
        , ( "toFloat just eq", show (String.toFloat "1.5" == Just 1.5) )
        , ( "pow 3 33", show (3 ^ 33) )
        ]


main : Program () () ()
main =
    worker report
