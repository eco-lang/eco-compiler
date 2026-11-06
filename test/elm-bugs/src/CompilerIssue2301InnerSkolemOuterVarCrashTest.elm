module CompilerIssue2301InnerSkolemOuterVarCrashTest exposing (main)

{-| The compiler reports a type error when a let annotation's type variable must equal the type of an enclosing function's argument.

<https://github.com/elm/compiler/issues/2301>

`g : (a -> ()) -> ()` promises to work for every `a`, but `g h = h x` passes `x`, an argument of
`f` with one type. Elm 0.19.1 crashes instead ("a [rank = 2]", Type/Solve.hs:206, "thread blocked
indefinitely in an MVar operation").

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
