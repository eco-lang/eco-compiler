module CompilerIssue2153RecursiveCallWrongArgCrashTest exposing (main)

{-| A recursive call with an argument of the wrong type crashes the compiler.

<https://github.com/elm/compiler/issues/2153>

`fooHelp toString firstItem remainingItems` passes `firstItem : a` where a `String` is expected: a TYPE MISMATCH. Elm 0.19.1 crashes ("? [rank = 1]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation").

-}

-- COMPILE-ERROR: TYPE MISMATCH, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


main =
    text "done"


foo : (a -> String) -> List a -> Maybe String
foo toString items =
    case items of
        firstItem :: remainingItems ->
            fooHelp toString (toString firstItem) remainingItems

        _ ->
            Nothing


fooHelp : (a -> String) -> String -> List a -> Maybe String
fooHelp toString firstString currentItems =
    case currentItems of
        firstItem :: remainingItems ->
            fooHelp toString firstItem remainingItems

        [] ->
            Nothing
