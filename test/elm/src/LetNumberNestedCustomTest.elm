module LetNumberNestedCustomTest exposing (main)

{-| Probe: `number` nested TWO constructors deep (`Box (NumBox 30)`), projected at
`Float` via a nested `case` pattern. The shape gate excludes boxed nested customs
from the eager number path, so this stresses the two-ctor-deep refinement.
Correct: 30*1.5 = 45.
-}

-- CHECK: nestcustom: 45

import Html exposing (text)


type Box a
    = Box a


type NumBox number
    = NumBox number


main =
    let
        v =
            Box (NumBox 30)

        result =
            case v of
                Box (NumBox n) ->
                    round (n * 1.5)

        _ =
            Debug.log "nestcustom" result
    in
    text "done"
