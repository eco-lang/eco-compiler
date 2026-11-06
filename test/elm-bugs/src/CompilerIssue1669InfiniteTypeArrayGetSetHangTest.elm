module CompilerIssue1669InfiniteTypeArrayGetSetHangTest exposing (main)

{-| An infinite type through `Array.get`/`Array.set` in a pipeline.

<https://github.com/elm/compiler/issues/1669>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

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
