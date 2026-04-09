module PureMutualRecursiveValueTest exposing (main)

{-| Mutually recursive zero-arity top-level values.

    Two bindings `a` and `b` each wrap a lambda that captures the other.
    Same mechanism as PureRecursiveValueThunkTest but with mutual recursion.

    Expected: prints "ok: ()" without crashing.
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
