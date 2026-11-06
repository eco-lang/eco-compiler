module CompilerIssue1550RecordExtensionDuplicateFieldTest exposing (..)

{-| Extending a record type with a field it already has is accepted, and the field's type is replaced.

<https://github.com/elm/compiler/issues/1550>

`A B` is `{ { x : String } | x : Int }`, a record with two `x` fields. Elm 0.19.1 accepts it
(and `{ x = 1 }` as a value of it); a duplicate field should be a compile error, as it is
everywhere else.

-}

-- COMPILE-ERROR: duplicate field x through record extension
-- CHECK: {{-- [A-Z ]+ -}}

import Html


type alias A a =
    { a | x : Int }


type alias B =
    { x : String }


test : A B
test =
    { x = 1 }


main =
    Html.text ""
