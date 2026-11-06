module CompilerIssue2106FoldlExtensibleRecordHangTest exposing (main)

{-| An infinite extensible-record type through `List.foldl`.

<https://github.com/elm/compiler/issues/2106>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type Room a = Room

type Window = Window

withWindow : Window -> Room a -> Room { a | withWindow : () }
withWindow window room =
    Room

withWindows : List Window -> Room a -> Room { a | withWindow : () }
withWindows windows room =
    List.foldl withWindow Room windows


main =
    Html.text ""
