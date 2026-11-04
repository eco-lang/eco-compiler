module ListMapNKernelClosureKindTest exposing (main)

{-| kernelListMapN (plans/kernel-lib-bug-fixes.md, Phase 2, X1): `List.map2` .. `List.map5` with
a point-free kernel function whose result type is polymorphic (`Debug.log`). The closure of a
polymorphic-result kernel returns its result boxed (kind 0), and the native list kernel stored
each result in the closure's own result kind, so the resulting `List Int` had boxed heads,
which code compiled for a `List Int` reads as raw Ints (HEAP_046). Expected output recorded
from Elm on node (run-js-e2e.js --record).
-}

-- CHECK-DAG: f: 1.5
-- CHECK-DAG: g: 2.5
-- CHECK-DAG: c: 'x'
-- CHECK-DAG: d: 'y'
-- CHECK-DAG: a: 66108864
-- CHECK-DAG: b: 2
-- CHECK-DAG: sum2: 66108866
-- CHECK-DAG: allLt2: True
-- CHECK-DAG: sum3: 4
-- CHECK-DAG: allLt3: True
-- CHECK-DAG: chars: "xy"
-- CHECK-DAG: eq2: True

import Platform


report : ()
report =
    let
        m2 : List Int
        m2 =
            List.map2 Debug.log [ "a", "b" ] [ 66108864, 2 ]

        m3 : List Float
        m3 =
            List.map3 (\_ -> Debug.log) [ (), () ] [ "f", "g" ] [ 1.5, 2.5 ]

        m2c : List Char
        m2c =
            List.map2 Debug.log [ "c", "d" ] [ 'x', 'y' ]

        _ =
            Debug.log "sum2" (List.sum m2)

        _ =
            Debug.log "allLt2" (List.all (\h -> h < 67108864) m2)

        _ =
            Debug.log "sum3" (List.sum m3)

        _ =
            Debug.log "allLt3" (List.all (\h -> h < 3.0) m3)

        _ =
            Debug.log "chars" (String.fromList m2c)

        _ =
            Debug.log "eq2" (m2 == [ 66108864, 2 ])
    in
    ()


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
