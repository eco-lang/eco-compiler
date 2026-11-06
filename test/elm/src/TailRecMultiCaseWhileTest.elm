module TailRecMultiCaseWhileTest exposing (main)

{-| A tail-recursive fold over a list of custom-type values, with a `case` on string literals nested inside one list pattern and tail calls in every branch, accumulates the right pair of totals.

`processItems` walks `[ Plain 3, Named "bonus" 2, Skip, Named "penalty" 1, Plain 2 ]`:
`"bonus"` adds twice its number, `"penalty"` subtracts its number, and both count
as special, so the total is 3 + 4 - 1 + 2 = 8 and the special count is 2.
-}

-- CHECK: total: 8
-- CHECK: special: 2

import Html exposing (text)


type Item
    = Named String Int
    | Plain Int
    | Skip


processItems : List Item -> Int -> Int -> ( Int, Int )
processItems items total specialCount =
    case items of
        [] ->
            ( total, specialCount )

        (Named tag n) :: rest ->
            case tag of
                "bonus" ->
                    processItems rest (total + n * 2) (specialCount + 1)

                "penalty" ->
                    processItems rest (total - n) (specialCount + 1)

                _ ->
                    processItems rest (total + n) specialCount

        (Plain n) :: rest ->
            processItems rest (total + n) specialCount

        Skip :: rest ->
            processItems rest total specialCount


main =
    let
        items =
            [ Plain 3, Named "bonus" 2, Skip, Named "penalty" 1, Plain 2 ]

        ( t, s ) =
            processItems items 0 0

        _ = Debug.log "total" t
        _ = Debug.log "special" s
    in
    text "done"
