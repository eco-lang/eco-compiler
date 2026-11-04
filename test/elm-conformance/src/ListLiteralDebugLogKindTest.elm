module ListLiteralDebugLogKindTest exposing (main)

{-| DEBUGLOG-INT-CMP companion (plans/kernel-lib-bug-fixes.md, Phase 2, X1): a value that came back
from `Debug.log` used where its static type decides the representation. A list literal used to
choose each head's slot kind from the element's SSA type, and `Debug.log` yielded its argument
boxed, so `[ d, d ]` with `d = Debug.log "d" 66108864` built a `List Int` with boxed heads that
`List.sum` read as raw Ints. The other uses (a closure capture, a tuple, a direct call, `::`, and
Float, Char and Bool list literals) pin the neighbouring paths. Expected output recorded from Elm
on node (run-js-e2e.js --record).
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
