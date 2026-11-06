module CompilerIssue2274MutualRecursionTransmuteTest exposing (main)

{-| Mutually recursive functions without annotations get a too-general type, so a value can be
cast to any type.

<https://github.com/elm/compiler/issues/2274>

`f x y = g x y` and `g x y = if False then f x y else y` have the type `a -> b -> b`, but Elm 0.19.1
infers `f : a -> b -> c`, so `eraseType : a -> b` type-checks and turns a String into an Int.
The annotation on `eraseType` must be rejected.

-}

-- COMPILE-ERROR: TYPE MISMATCH, eraseType's annotation is more general than f allows
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


f x y =
    g x y


g x y =
    if False then
        f x y

    else
        y


eraseType : a -> b
eraseType x =
    f () x


main =
    text (String.fromInt (eraseType "not an Int" + 1))
