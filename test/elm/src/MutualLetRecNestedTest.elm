module MutualLetRecNestedTest exposing (main)

{-| Two mutually recursive `let`-bound functions defined inside a lambda that is returned from a top-level function use that function's parameters after it has returned.

`makeClassifier 10 11 12 9` returns a function of `n` that starts in `innerBig`
and alternates with `innerSmall` until `k` reaches `0`. Ending in `innerSmall`
gives the parameter sum `42`; ending in `innerBig` gives twice that, `84`. So
odd `n` logs `42` and even `n` logs `84`.
-}

-- CHECK: run 3: 42
-- CHECK: run 2: 84
-- CHECK: run 1: 42
-- CHECK: run 0: 84


import Html exposing (text)


makeClassifier : Int -> Int -> Int -> Int -> (Int -> Int)
makeClassifier extA extB extC extD =
    \n ->
        let
            innerSmall k =
                if k <= 0 then
                    extA + extB + extC + extD

                else
                    innerBig (k - 1)

            innerBig k =
                if k <= 0 then
                    2 * (extA + extB + extC + extD)

                else
                    innerSmall (k - 1)
        in
        innerBig n


main =
    let
        classifier =
            makeClassifier 10 11 12 9

        _ =
            Debug.log "run 3" (classifier 3)

        _ =
            Debug.log "run 2" (classifier 2)

        _ =
            Debug.log "run 1" (classifier 1)

        _ =
            Debug.log "run 0" (classifier 0)
    in
    text "done"
