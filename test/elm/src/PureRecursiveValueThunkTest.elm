module PureRecursiveValueThunkTest exposing (main)

{-| A top-level value that refers to itself inside a lambda can be defined and used.

`me` is `Box (\_ -> me)`: it is a value, not a function, and refers to itself only inside a
lambda, which Elm allows. `main` matches `me` against `Box _` and logs `ok: ()`; the lambda
is never called.

-}

-- CHECK: ok: ()

import Html exposing (text)


type Box
    = Box (() -> Box)


me : Box
me =
    Box (\_ -> me)


main =
    let
        _ =
            case me of
                Box _ ->
                    Debug.log "ok" ()
    in
    text "done"
