module CompilerIssue2106FoldlExtensibleRecordHangTest exposing (main)

{-| A `List.foldl` whose step function extends an extensible-record type parameter must be
rejected with a type error, not hang the compiler.

<https://github.com/elm/compiler/issues/2106>

`List.foldl withWindow Room windows` needs `Room a` and `Room { a | withWindow : () }` to be the
same type, which would make the record type infinite. Elm 0.19.1 instead hangs while its memory
grows without bound, or crashes.

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
