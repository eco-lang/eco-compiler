module NumberGenericAppCustom exposing (main)

{-| A number literal passed through a generic function, here `unbox : Box a ->
a` applied to `Box 30`, keeps the type `number`, so the `let`-bound result
can be used in `Float` arithmetic: `round (1.5 * n)` logs 45.
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
