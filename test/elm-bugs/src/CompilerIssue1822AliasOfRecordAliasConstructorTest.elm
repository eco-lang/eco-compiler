module CompilerIssue1822AliasOfRecordAliasConstructorTest exposing (..)

{-| An alias of a record type alias has no record constructor.

<https://github.com/elm/compiler/issues/1822>

`Y` is an alias of the record alias `X`, so `Y` should construct an `X` like `X` does. Elm 0.19.1
reports "I cannot find a `Y` variant".

-}

-- CHECK: y: { a = "a", b = "b" }

import Html exposing (text)


type alias X =
    { a : String, b : String }


type alias Y =
    X


main =
    let
        _ =
            Debug.log "y" (Y "a" "b")
    in
    text "done"
