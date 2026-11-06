module CompilerIssue2295LambdaLetAnnotationCrashTest exposing (main)

{-| The compiler reports a TYPE MISMATCH for a let annotation `b : b` whose value is a lambda argument.

<https://github.com/elm/compiler/issues/2295>

`b : b` claims `b` can be any type, but its value is the argument `a` of the lambda that defines
`test`. Elm 0.19.1 crashes instead ("b [rank = 2]", Type/Solve.hs:206, "thread blocked
indefinitely in an MVar operation").

-}

-- COMPILE-ERROR: TYPE MISMATCH, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


main =
    text "done"


test : a -> a
test =
    \a ->
        let
            b : b
            b =
                a
        in
        b
