module MutualLetRecManyCapturesTest exposing (main)

{-| Two mutually recursive `let`-bound functions inside a top-level function, both using all four of the enclosing function's parameters, compute the right result.

`classify 10 11 12 9 n` alternates between `innerSmall` and `innerBig` until
`k` reaches `0`, and either base case returns `10 + 11 + 12 + 9 = 42`. The
extra term in `innerBig` is multiplied by `0`, so every `n` from `3` down to
`0` logs `42`.
-}

-- CHECK: go 3: 42
-- CHECK: go 2: 42
-- CHECK: go 1: 42
-- CHECK: go 0: 42


import Html exposing (text)


{-| Returns `extA + extB + extC + extD` for any `n`, reached by alternating between two
mutually recursive local functions.
-}
classify : Int -> Int -> Int -> Int -> Int -> Int
classify extA extB extC extD n =
    let
        innerSmall k =
            if k <= 0 then
                extA + extB + extC + extD

            else
                innerBig (k - 1)

        innerBig k =
            if k <= 0 then
                extA + extB + extC + extD

            else
                innerSmall (k - 1) + 0 * (extA - extB + extC - extD)
    in
    innerSmall n


main =
    let
        a =
            10

        b =
            11

        c =
            12

        d =
            9

        _ =
            Debug.log "go 3" (classify a b c d 3)

        _ =
            Debug.log "go 2" (classify a b c d 2)

        _ =
            Debug.log "go 1" (classify a b c d 1)

        _ =
            Debug.log "go 0" (classify a b c d 0)
    in
    text "done"
