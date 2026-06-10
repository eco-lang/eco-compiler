module NumberGenericAppList exposing (main)

{-| Number-multi gate relaxation regression (Mechanism B): a scalar `number`
element through `List.head : List a -> Maybe a` (generic-call RHS). Constraint
intact; rejected by `isNumericDataRhs`; defaulted to Int; miscompiled at Float.
Correct: round (1.5 * 30) = 45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


main =
    let
        n =
            Maybe.withDefault 0 (List.head [ 30 ])

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
