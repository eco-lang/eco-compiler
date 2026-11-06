module CompilerIssue1896ExtendCustomTypeCrashTest exposing (..)

{-| Extending a custom type as if it were a record crashes the compiler while reporting the error.

<https://github.com/elm/compiler/issues/1896>

`Model Bad` extends the non-record `Bad`. Elm 0.19.1 starts a TYPE MISMATCH report and then
crashes ("Used toErrorType on a type that is not well-formed"); it should report the error.

-}

-- COMPILE-ERROR: extending a non-record
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: not well-formed

import Html


type alias Model record =
    { record | a : () }


type Bad
    = Bad


worker : Program () (Model Bad) ()
worker =
    Platform.worker
        { init = always ( { a = () }, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = always Sub.none
        }


main =
    Html.text ""
