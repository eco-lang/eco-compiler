module CompilerIssue2301InnerSkolemOuterVarCrashTest exposing (main)

{-| Unifying a let annotation's type variable with a variable of the enclosing function crashes the compiler.

<https://github.com/elm/compiler/issues/2301>

In `g : (a -> ()) -> ()`, `g h = h x` needs `x : a` for every `a`, but `x` has one fixed type: a type error. Elm 0.19.1 crashes ("a [rank = 2]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation").

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


f x =
    let
        g : (a -> ()) -> ()
        g h =
            h x
    in
    x
