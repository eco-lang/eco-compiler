module CompilerIssue2077RankCrashExtensibleLetAnnotationTest exposing (..)

{-| A `let` annotation that gives an unannotated argument a more general extensible-record type
must be reported as a type error, not crash the compiler.

<https://github.com/elm/compiler/issues/2077>

`fn_ : { a | foo : Int } -> Bool` claims the argument `fn` works for every `a`, but `fn` is a
plain argument of `test` and is not polymorphic. Elm 0.19.1 crashes
("You ran into a compiler bug", `a [rank = 2]`); it should report a type error.

-}

-- COMPILE-ERROR: let annotation is too general
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


test fn a =
    let
        fn_ : { a | foo : Int } -> Bool
        fn_ =
            fn

        a_ : { foo : Int }
        a_ =
            a
    in
    fn_ a_


main =
    Html.text ""
