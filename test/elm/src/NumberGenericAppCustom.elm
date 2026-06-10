module NumberGenericAppCustom exposing (main)

{-| Number-multi gate relaxation regression (Mechanism B): a scalar `number`
through a user constructor `unbox : Box a -> a` (generic-call RHS). Constraint
intact; rejected by `isNumericDataRhs`; defaulted to Int; miscompiled at Float.
Correct: round (1.5 * 30) = 45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


type Box a
    = Box a


unbox : Box a -> a
unbox (Box x) =
    x


main =
    let
        n =
            unbox (Box 30)

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
