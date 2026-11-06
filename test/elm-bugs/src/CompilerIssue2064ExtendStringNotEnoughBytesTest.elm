module CompilerIssue2064ExtendStringNotEnoughBytesTest exposing (..)

{-| Extending `String` as if it were a record inside a custom type crashes the compiler.

<https://github.com/elm/compiler/issues/2064>

`Named String`, a constructor argument of `Something`, extends the non-record `String`. Elm 0.19.1
crashes; it should report an error.

-}

-- COMPILE-ERROR: extending a non-record
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: CallStack

import Html


type alias Named a =
    { a | name : String }


type Something
    = Something (Named String)


type alias Model =
    { something : Something }


init =
    { something = Something }


main =
    Html.text ""
