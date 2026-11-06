module CompilerIssue2027IncompatibleExtensibleRecordsHangTest exposing (main)

{-| Using one value as two incompatible extensible records (`Tricky x x`) must be a type error.

<https://github.com/elm/compiler/issues/2027>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound, or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type Tricky r
    = Tricky { r | a : Int } { r | b : Int }


mkTricky x =
    Tricky x x


main =
    Html.text ""
