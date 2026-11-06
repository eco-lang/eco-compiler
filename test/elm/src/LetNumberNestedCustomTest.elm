module LetNumberNestedCustomTest exposing (main)

{-| An integer literal nested two custom-type constructors deep is used as a
`Float`: `Box (NumBox 30)`, matched by the pattern `Box (NumBox n)` and
multiplied by `1.5`, logs 45.

`Box` and `NumBox` are each a single-constructor type with one type parameter;
`NumBox`'s parameter is named `number`, which makes it a constrained type
variable.

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
