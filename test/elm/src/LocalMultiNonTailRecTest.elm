module LocalMultiNonTailRecTest exposing (main)

{-| A let-bound recursive function that is not tail recursive, with an
unannotated polymorphic type, is used at both Int and Float in the same body.

`sumL` sums a list with `x + sumL rest`, so its type is `List number -> number`.
It is applied to `[ 1, 2, 3 ]` (Int, sum 6) and to `[ 0.5, 1.5, 2.0 ]`
(Float, sum 4). Each use's recursive calls must stay at that use's own type.
-}

import Html exposing (text)


-- CHECK: sumInt: 6
-- CHECK: sumFloat: 4


main =
    let
        sumL xs =
            case xs of
                [] ->
                    0

                x :: rest ->
                    x + sumL rest

        a =
            sumL [ 1, 2, 3 ]

        b =
            sumL [ 0.5, 1.5, 2.0 ]

        _ =
            Debug.log "sumInt" a

        _ =
            Debug.log "sumFloat" b
    in
    text "done"
