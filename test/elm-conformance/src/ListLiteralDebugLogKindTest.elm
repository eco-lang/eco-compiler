module ListLiteralDebugLogKindTest exposing (main)

{-| Values returned by `Debug.log` keep their value when used in a closure, a tuple, a function
argument, a list literal and a `::` cons.

`d` is `Debug.log "d" 66108864`. The tests compare it, through each of those uses, against
67108864 (2^26) or add it up: `sumLit` sums `[ d, d ]`. A `Float`, a `Char` and a `Bool` from
`Debug.log` are each put in a one- or two-element list literal and read back.

-}

-- CHECK-DAG: fl: 1.5
-- CHECK-DAG: d: 66108864
-- CHECK-DAG: c: 'q'
-- CHECK-DAG: b: True
-- CHECK-DAG: capture: True
-- CHECK-DAG: tuple: True
-- CHECK-DAG: call: True
-- CHECK-DAG: sumLit: 132217728
-- CHECK-DAG: consOp: True
-- CHECK-DAG: floatLit: True
-- CHECK-DAG: charLit: "qq"
-- CHECK-DAG: boolLit: True

import Platform


addTo : Int -> Int -> Int
addTo a b =
    a + b


report : ()
report =
    let
        d =
            Debug.log "d" 66108864

        f =
            \x -> x + d < 67108864 + 5

        _ =
            Debug.log "capture" (f 3)

        _ =
            Debug.log "tuple" (Tuple.first ( d, 1 ) < 67108864)

        _ =
            Debug.log "call" (addTo d 1 < 67108864)

        _ =
            Debug.log "sumLit" (List.sum [ d, d ])

        _ =
            Debug.log "consOp" (List.all (\h -> h < 67108864) (d :: []))

        fl =
            Debug.log "fl" 1.5

        _ =
            Debug.log "floatLit" (List.all (\h -> h < 2.0) [ fl ])

        c =
            Debug.log "c" 'q'

        _ =
            Debug.log "charLit" (String.fromList [ c, c ])

        b =
            Debug.log "b" True

        _ =
            Debug.log "boolLit" (List.all identity [ b ])
    in
    ()


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
