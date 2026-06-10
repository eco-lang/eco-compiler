module NumberGenericAppMaybe exposing (main)

{-| Number-multi gate relaxation regression (Mechanism B): a scalar `number`
through `Maybe.withDefault : a -> Maybe a -> a` (a generic-call RHS). Constraint
intact; rejected by `isNumericDataRhs`; defaulted to Int; miscompiled at Float.
Correct: round (1.5 * 30) = 45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


main =
    let
        n =
            Maybe.withDefault 0 (Just 30)

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
