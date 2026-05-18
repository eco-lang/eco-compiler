module CrossSpecMutualRecursiveTest exposing (main)

{-| Phase 3.2 #1 end-to-end positive integration test for SCC-aware
mutual recursion.

`evenPair` and `oddPair` form a 2-member SCC over a tuple2 param.
Both must specialise (each gets a $unboxed worker) and intra-SCC
calls must thread the aggregate directly through workers without
re-boxing at every step.

Compute: evenPair (1, 6) 5
       → oddPair  (1, 6) 4
       → evenPair (1, 6) 3
       → oddPair  (1, 6) 2
       → evenPair (1, 6) 1
       → oddPair  (1, 6) 0
       → b = 6

-}

-- CHECK: result: 6


import Html exposing (text)


evenPair : ( Int, Int ) -> Int -> Int
evenPair pair n =
    if n <= 0 then
        case pair of
            ( a, _ ) ->
                a

    else
        oddPair pair (n - 1)


oddPair : ( Int, Int ) -> Int -> Int
oddPair pair n =
    if n <= 0 then
        case pair of
            ( _, b ) ->
                b

    else
        evenPair pair (n - 1)


main =
    let
        result =
            evenPair ( 1, 6 ) 5

        _ =
            Debug.log "result" result
    in
    text "done"
