module PureMutualRecursiveValueTest exposing (main)

{-| Two top-level values that refer to each other through lambdas can be defined and used.

`a` is `Box (\_ -> b)` and `b` is `Box (\_ -> a)`: neither is a function, but each refers
to the other only inside a lambda, which Elm allows. `main` unwraps `a`, calls its function
to get `b`, matches that, and logs `ok: ()`.

-}

-- CHECK: ok: ()

import Html exposing (text)


type Box
    = Box (() -> Box)


a : Box
a =
    Box (\_ -> b)


b : Box
b =
    Box (\_ -> a)


main =
    let
        _ =
            case a of
                Box f ->
                    case f () of
                        Box _ ->
                            Debug.log "ok" ()
    in
    text "done"
