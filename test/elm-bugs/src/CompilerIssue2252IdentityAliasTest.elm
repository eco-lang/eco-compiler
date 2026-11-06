module CompilerIssue2252IdentityAliasTest exposing (main)

{-| A type alias `Identity a = a` does not unify with `a` in an annotation.

<https://github.com/elm/compiler/issues/2252>

`Identity a` is by definition `a`, so `map : (a -> b) -> Identity a -> Identity b` is the type
`(a -> b) -> a -> b` and `map change = change` is correct. Elm 0.19.1 rejects it with a TYPE
MISMATCH (`a -> b` vs `Identity a -> Identity b`).

-}

-- CHECK: map: 3

import Html exposing (text)


type alias Identity a =
    a


map : (a -> b) -> Identity a -> Identity b
map change =
    change


main =
    let
        _ =
            Debug.log "map" (map String.length "abc")
    in
    text "done"
