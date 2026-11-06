module CompilerIssue2036LensRecordUpdateHangTest exposing (main)

{-| A lens whose setter takes its arguments in the wrong order must be a type error.

<https://github.com/elm/compiler/issues/2036>

`set` is declared `b -> a -> a`, but the lambda takes the record first, so the program is
ill-typed and must be rejected with a type error. Elm 0.19.1 instead hangs while its memory grows
without bound, or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type alias Lens a b =
    { get : a -> b
    , set : b -> a -> a
    }


type alias State inputState =
    { input : inputState }


inputLens : Lens (State inputState) inputState
inputLens =
    Lens .input (\a b -> { a | input = b })


main =
    Html.text ""
