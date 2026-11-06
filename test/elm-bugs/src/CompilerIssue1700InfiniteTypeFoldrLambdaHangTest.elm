module CompilerIssue1700InfiniteTypeFoldrLambdaHangTest exposing (main)

{-| An infinite type in a `List.foldr` lambda (`uniq :: elem`).

<https://github.com/elm/compiler/issues/1700>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


listUnique : List a -> List a
listUnique lst =
    List.foldr
        (\elem uniq ->
            if List.member elem uniq then
                uniq

            else
                uniq :: elem
        )
        []
        lst


main =
    Html.text ""
