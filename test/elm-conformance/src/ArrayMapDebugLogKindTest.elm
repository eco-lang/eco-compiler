module ArrayMapDebugLogKindTest exposing (main)

{-| ARRAY-NEW-1 / ARRAY-05 (plans/kernel-lib-bug-fixes.md): `Array.map` and `Array.initialize`
with a point-free kernel function whose result type is polymorphic (`Debug.log "x"`). The
closure of a polymorphic-result kernel returns its result boxed (kind 0). The native JsArray
kernel used to store each result in the closure's own result kind, so the resulting `Array Int`
was a kind-0 (boxed) array although every later Int-typed operation treats it as kind 1: `get`
read a pointer as an Int, and `Array.push` (`elm_array_push_int`) wrote a raw Int into a boxed
array (ARRAY-05), which a minor GC then traced as a pointer. The compiler now selects the
`map_Int` / `initialize_Int_Int` kernel variants by the result's element type, and they store
every element as an Int. The `big` map goes through the RRB tree as well as the tail. `churn`
depends on `pushed`, so it runs after it, and allocates enough to run minor GCs while the pushed
array is live; `after-gc` uses the array afterwards. Expected output recorded from Elm on node
(run-js-e2e.js --record).
-}

-- CHECK-DAG: x: 1
-- CHECK-DAG: x: 2
-- CHECK-DAG: x: 3
-- CHECK-DAG: i: 0
-- CHECK-DAG: i: 1
-- CHECK-DAG: i: 2
-- CHECK-DAG: y: 36
-- CHECK-DAG: get0: Just 1
-- CHECK-DAG: get2i: Just 2
-- CHECK-DAG: pushed: [1,2,3,4]
-- CHECK-DAG: sum: 6
-- CHECK-DAG: eq: True
-- CHECK-DAG: bigGet: Just 36
-- CHECK-DAG: churn: 90000300004
-- CHECK-DAG: after-gc: [1,2,3,4]

import Array exposing (Array)


report : ()
report =
    let
        m : Array Int
        m =
            Array.map (Debug.log "x") (Array.fromList [ 1, 2, 3 ])

        i : Array Int
        i =
            Array.initialize 3 (Debug.log "i")

        big : Array Int
        big =
            Array.map (Debug.log "y") (Array.fromList (List.range 1 40))

        _ =
            Debug.log "get0" (Array.get 0 m)

        _ =
            Debug.log "get2i" (Array.get 2 i)

        pushed : Array Int
        pushed =
            Array.push 4 m

        _ =
            Debug.log "pushed" (Array.toList pushed)

        _ =
            Debug.log "sum" (Array.foldl (+) 0 m)

        _ =
            Debug.log "eq" (m == Array.fromList [ 1, 2, 3 ])

        _ =
            Debug.log "bigGet" (Array.get 35 big)

        churn : Int
        churn =
            Debug.log "churn" (List.sum (List.map (\k -> k * 2) (List.range 1 300000)) + Array.length pushed)
    in
    if churn > 0 then
        let
            _ =
                Debug.log "after-gc" (Array.toList pushed)
        in
        ()

    else
        ()


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
