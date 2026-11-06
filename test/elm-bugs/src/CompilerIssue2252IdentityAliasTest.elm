module CompilerIssue2252IdentityAliasTest exposing (main)

{-| A type alias `Identity a = a` is interchangeable with `a`, so `map change = change` type-checks against `(a -> b) -> Identity a -> Identity b`.

<https://github.com/elm/compiler/issues/2252>

The annotation means `(a -> b) -> a -> b`, and `map String.length "abc"` should print 3. Elm 0.19.1
rejects the definition with a TYPE MISMATCH between `a -> b` and `Identity a -> Identity b`.

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
