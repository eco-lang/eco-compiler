module CompilerIssue2097ExtensibleUnitArgCrashTest exposing (main, f)

{-| An extensible-record alias applied to `()` must be rejected with an error report, not crash
the compiler.

<https://github.com/elm/compiler/issues/2097>

Elm 0.19.1 crashes with "Used toAnnotation on a type that is not well-formed" (Type/Type.hs) and
"thread blocked indefinitely in an MVar operation". `()` is not a record, so the program must be
rejected with an ordinary error report.

-}

-- COMPILE-ERROR: an ordinary error report, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK-NOT: not well-formed
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


type alias Extensible comparable a =
    { a | id : comparable }


type alias T =
    Extensible String ()


f : List T -> List String
f list =
    List.map .id list
