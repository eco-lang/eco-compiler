module CompilerIssue2184LetRecursionTooManyArgsCrashTest exposing (main)

{-| Two let-bound recursive functions that call themselves with too many arguments must be
reported as a type error, not crash the compiler.

<https://github.com/elm/compiler/issues/2184>

`f1 a b c` and `f2 a d e` pass three arguments to two-argument functions: a TOO MANY ARGS / type
error. Elm 0.19.1 crashes ("? [rank = 1]", Type/Solve.hs:206, "thread blocked indefinitely in an
MVar operation").

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


func : Int -> Int
func a =
    let
        f1 : number -> Int -> Int
        f1 b c =
            f1 a b c

        f2 : number -> Int -> Int
        f2 d e =
            f2 a d e
    in
    0
