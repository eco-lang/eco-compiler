module CompilerIssue2036LensRecordUpdateHangTest exposing (main)

{-| An ill-typed lens: the setter takes its arguments in the wrong order.

<https://github.com/elm/compiler/issues/2036>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

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
