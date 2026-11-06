module CompilerIssue2108IfBranchExtensibleRecordHangTest exposing (main)

{-| `if` branches of incompatible extensible-record function types.

<https://github.com/elm/compiler/issues/2108>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type Thing b
    = Thing

changesTypeVariable : Thing { b | something : () } -> Thing { b | somethingElse : () }
changesTypeVariable _ =
    Thing

foo =
    if True then
        changesTypeVariable

    else
        identity


main =
    Html.text ""
