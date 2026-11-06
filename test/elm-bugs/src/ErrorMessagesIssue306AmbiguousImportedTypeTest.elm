module ErrorMessagesIssue306AmbiguousImportedTypeTest exposing (main)

{-| Two imports that both expose a type of the same name (`Decoder` from Json.Decode and from
Bytes.Decode) make an unqualified use of that type ambiguous, but the compiler silently picks
one of them.

<https://github.com/elm/error-message-catalog/issues/306>

Elm 0.19.1 takes `Decoder` to mean the one from the last import (`Json.Decode.Decoder`) and
compiles this program. An ambiguous value name is an AMBIGUOUS NAME error, and an ambiguous type
name should be an ambiguity error too (the check accepts any AMBIGUOUS title).

-}

-- COMPILE-ERROR: unqualified type name exposed by two imports
-- CHECK: {{-- AMBIGUOUS [A-Z ]+ -}}

import Bytes.Decode exposing (Decoder)
import Html exposing (text)
import Json.Decode exposing (Decoder)


x : Decoder Int
x =
    Json.Decode.succeed 1


main =
    text "done"
