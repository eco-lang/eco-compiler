module MutualLetRecManyCapturesTest exposing (main)

{-| Bootstrap-stage regression: mutually-recursive closure group where one
sibling captures several non-sibling variables plus the peer sibling, and
the other sibling has only the peer-sibling capture (no non-sibling
captures). This mirrors the shape that the compiler itself emits inside
`Terminal.Main.lambda_15903$cap` (siblings with `cc=0` and `cc=4`).

The original bug showed as `llvm.call` op operand type mismatch for
operand 1: 'i64' != '!llvm.ptr<1>' at stage 6 of the bootstrap.

-}

-- CHECK: go 3: 42
-- CHECK: go 2: 42
-- CHECK: go 1: 42
-- CHECK: go 0: 42


import Html exposing (text)


{-| `innerSmall` has only the peer capture (`innerBig`) — no non-sibling
captures. `innerBig` captures four external values (`extA..extD`) plus the
peer (`innerSmall`). Both siblings have exactly one remaining parameter.
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
