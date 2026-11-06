module ArrayMapDebugLogKindTest exposing (main)

{-| `Array.map` and `Array.initialize` with a point-free `Debug.log` as the function give an
`Array Int` that later Array operations read correctly.

`Debug.log "x"` returns its argument unchanged and has the polymorphic type `a -> a`, so each
mapped array's element type is fixed by its input and its `Array Int` annotation. The test builds three such arrays: `m`
maps `Debug.log "x"` over `[1,2,3]`, `i` is `Array.initialize 3 (Debug.log "i")`, and `big` maps
`Debug.log "y"` over 1 to 40.

  - `x` and `i`: each element is logged once as it is produced (in any order).
  - `get0`, `get2i`, `bigGet`: `Array.get` returns the mapped Int, including index 35 of `big`.
  - `pushed`: `Array.push 4` onto `m` gives `[1,2,3,4]`.
  - `sum` and `eq`: `Array.foldl (+)` sums `m` to 6, and `m` equals `Array.fromList [1,2,3]`.
  - `churn` and `after-gc`: after summing the doubles of a 300,000-element list (plus the pushed
    array's length), the pushed array still converts back to `[1,2,3,4]`.

Among what is not tested: `Debug.log` output for the other 39 elements of `big`.
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
