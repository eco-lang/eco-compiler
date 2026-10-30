module FloatToIntRangeTest exposing (main)

{-| Float to Int conversions whose Elm result is not a 64-bit integer. On node an Int is a JS
number: round, floor and ceiling of NaN or Infinity give NaN or Infinity, and truncate is
`n | 0`, which wraps to 32 bits. Natively an Int is i64, so none of these can match; the test
records Elm's behaviour so the divergence stays visible. Expectations recorded from Elm on node
(run-js-e2e.js --record).
-}

-- XFAIL-NATIVE: deliberate divergence from Elm (design_docs/float-semantics.md, CGEN_086): Int
-- is i64 and the conversion saturates (NaN gives 0), with no 32-bit wrap in truncate
-- CHECK: round nan: "NaN"
-- CHECK: floor nan: "NaN"
-- CHECK: ceiling nan: "NaN"
-- CHECK: round inf: "Infinity"
-- CHECK: truncate 3e10: "-64771072"

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


report : ()
report =
    logAll
        [ ( "round nan", show (round nan) )
        , ( "floor nan", show (floor nan) )
        , ( "ceiling nan", show (ceiling nan) )
        , ( "round inf", show (round inf) )
        , ( "truncate 3e10", show (truncate 3.0e10) )
        ]


main : Program () () ()
main =
    worker report
