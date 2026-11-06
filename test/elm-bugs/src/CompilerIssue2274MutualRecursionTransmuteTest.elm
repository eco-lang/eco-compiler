module CompilerIssue2274MutualRecursionTransmuteTest exposing (main)

{-| The compiler rejects `eraseType : a -> b` because the unannotated mutually recursive `f` and `g` only have type `a -> b -> b`.

<https://github.com/elm/compiler/issues/2274>

`g` returns its second argument and `f` returns whatever `g` does, so `f () x` has the type of `x`
and the annotation on `eraseType` is too general: a TYPE MISMATCH. Elm 0.19.1 infers
`f : a -> b -> c` instead, accepts the program, and lets `eraseType` turn a `String` into an `Int`.

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
