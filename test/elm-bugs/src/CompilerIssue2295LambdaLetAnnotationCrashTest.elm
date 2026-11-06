module CompilerIssue2295LambdaLetAnnotationCrashTest exposing (main)

{-| In a lambda, a let annotation with a fresh type variable for a lambda argument crashes the compiler.

<https://github.com/elm/compiler/issues/2295>

`b : b` claims `b` is any type, but its body is the lambda argument `a`: a TYPE MISMATCH, which Elm 0.19.1 reports when `a` is a named argument of `test`. With a lambda it crashes ("b [rank = 2]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation").

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
