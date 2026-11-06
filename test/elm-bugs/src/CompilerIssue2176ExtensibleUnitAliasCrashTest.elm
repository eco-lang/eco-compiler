module CompilerIssue2176ExtensibleUnitAliasCrashTest exposing (main, addExtension)

{-| Converting between records typed with an extensible alias applied to `()` crashes the compiler.

<https://github.com/elm/compiler/issues/2176>

`ExtensibleT () dataT` is ill-formed (`()` is not a record). Elm 0.19.1 crashes with "Used toAnnotation on a type that is not well-formed" and "thread blocked indefinitely in an MVar operation" instead of reporting an error.

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK-NOT: not well-formed
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


type alias ExtensibleT extension dataT =
    { extension | data : dataT }


type alias TWithOutExtension dataT =
    ExtensibleT () dataT


type alias TWithSimpleExtension dataT =
    ExtensibleT { simple : Int } dataT


addExtension : TWithOutExtension dataT -> TWithSimpleExtension dataT
addExtension { data } =
    { data = data, simple = 0 }
