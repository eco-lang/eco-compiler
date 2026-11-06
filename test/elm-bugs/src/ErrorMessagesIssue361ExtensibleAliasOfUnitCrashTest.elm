module ErrorMessagesIssue361ExtensibleAliasOfUnitCrashTest exposing (..)

{-| An extensible-record type alias applied to a non-record type (`ExtRec ()`) crashes the
compiler instead of reporting a type error.

<https://github.com/elm/error-message-catalog/issues/361>

Elm 0.19.1 dies with the internal error "Used toAnnotation on a type that is not well-formed"
("I ran into something that bypassed the normal error reporting process!"). It should reject
the program with an ordinary error report. (With `exposing (main)` instead of `exposing (..)`,
Elm 0.19.1 does not crash but compiles the program, accepting the ill-formed type.)

-}

-- COMPILE-ERROR: extensible record alias applied to the unit type
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting
-- CHECK-NOT: toAnnotation

import Html exposing (text)


type alias ExtRec a =
    { a | foo : Int }


type alias Model =
    ()


f : ExtRec Model
f =
    Debug.todo "implement"


main =
    text (String.fromInt f.foo)
