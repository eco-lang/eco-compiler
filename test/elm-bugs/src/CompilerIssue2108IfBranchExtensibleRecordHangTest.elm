module CompilerIssue2108IfBranchExtensibleRecordHangTest exposing (main)

{-| `if` branches of incompatible extensible-record function types must be rejected with a type
error, not hang the compiler.

<https://github.com/elm/compiler/issues/2108>

One branch is `changesTypeVariable`, from `Thing { b | something : () }` to
`Thing { b | somethingElse : () }`; the other is `identity`, which needs those two types to be
equal. Elm 0.19.1 instead hangs while its memory grows without bound, or crashes.

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
