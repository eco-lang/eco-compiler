module CompilerIssue2298IdentityAliasResultTest exposing (main)

{-| A type alias `Msg a = a` in the result of an annotation does not unify with `a`.

<https://github.com/elm/compiler/issues/2298> (also <https://github.com/elm/compiler/issues/2292>)

`make : a -> Msg a` is `a -> a`, so `make = identity` is correct. Elm 0.19.1 rejects it
(`a -> a` vs `a -> Msg a`), while it accepts `Msg a -> a`.

-}

-- CHECK: make: 7

import Html exposing (text)


type alias Msg a =
    a


make : a -> Msg a
make =
    identity


main =
    let
        _ =
            Debug.log "make" (make 7)
    in
    text "done"
