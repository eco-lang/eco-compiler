module CompilerIssue1700InfiniteTypeFoldrLambdaHangTest exposing (main)

{-| A `List.foldr` lambda that conses a list onto an element (`uniq :: elem`) is rejected with an infinite-type error.

<https://github.com/elm/compiler/issues/1700>

Elm 0.19.1 hangs on it, its memory growing without bound, instead of reporting the error.

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
