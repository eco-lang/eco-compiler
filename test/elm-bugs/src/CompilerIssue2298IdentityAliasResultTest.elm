module CompilerIssue2298IdentityAliasResultTest exposing (main)

{-| A type alias `Msg a = a` in an annotation's result is interchangeable with `a`, so `make = identity` type-checks against `a -> Msg a`.

<https://github.com/elm/compiler/issues/2298>

<https://github.com/elm/compiler/issues/2292>

The annotation means `a -> a`, and `make 7` should print 7. Elm 0.19.1 rejects the definition
(`a -> a` against `a -> Msg a`), although it accepts the alias in argument position.

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
