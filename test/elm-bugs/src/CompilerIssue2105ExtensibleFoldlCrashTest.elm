module CompilerIssue2105ExtensibleFoldlCrashTest exposing (main, withWindows)

{-| Folding with a function that extends a record type parameter must produce a complete type
error report, not crash the compiler.

<https://github.com/elm/compiler/issues/2105>

`List.foldl withWindow room windows` needs `Room a` and `Room { a | withWindow : () }` to be the
same type, which they are not. Elm 0.19.1 starts printing the TYPE MISMATCH report, then crashes
with "Used toErrorType on a type that is not well-formed" (Type/Type.hs:541).

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK-NOT: not well-formed
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


type Room a
    = Room


type Window
    = Window


withWindow : Window -> Room a -> Room { a | withWindow : () }
withWindow window room =
    Room


withWindows : List Window -> Room a -> Room { a | withWindow : () }
withWindows windows room =
    List.foldl withWindow room windows
