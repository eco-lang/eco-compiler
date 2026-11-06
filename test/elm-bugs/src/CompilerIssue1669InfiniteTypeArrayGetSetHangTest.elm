module CompilerIssue1669InfiniteTypeArrayGetSetHangTest exposing (main)

{-| A function whose type would be infinite, built from `Array.get` and `Array.set` in a pipeline, is rejected with a type error.

<https://github.com/elm/compiler/issues/1669>

Elm 0.19.1 hangs on it, its memory growing without bound, instead of reporting the error.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html
import Array exposing (Array)


fribble x y =
    Array.get y x
        |> Maybe.map (Array.set y x)
        |> Maybe.withDefault x


main =
    Html.text ""
