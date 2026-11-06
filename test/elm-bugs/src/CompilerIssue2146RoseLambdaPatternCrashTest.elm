module CompilerIssue2146RoseLambdaPatternCrashTest exposing (main)

{-| A type error involving a lambda pattern on a custom type must be reported normally, not crash
the compiler.

<https://github.com/elm/compiler/issues/2146>

In `tail`, the lambda's pattern `Branch _ xs` makes its argument a `Rose`, and `List.map f xs`
then needs `f`'s argument type `a` to be a `Rose` too, but the annotation makes `a` an arbitrary
type: a type error. Elm 0.19.1 crashes ("? [rank = 1]", Type/Solve.hs:206, "thread blocked
indefinitely in an MVar operation").

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


type Rose a
    = Branch a (List (Rose a))


type T a b
    = T (a -> b)


mapT2 : (b -> c -> d) -> T a b -> T a c -> T a d
mapT2 f (T g) (T h) =
    T (\x -> f (g x) (h x))


andMap : T a b -> T a (b -> c) -> T a c
andMap =
    mapT2 (|>)


succeed : b -> T a b
succeed x =
    T (\_ -> x)


andThen : (b -> T a c) -> T a b -> T a c
andThen f g =
    T
        (\x ->
            let
                v =
                    runT g x
            in
            runT (f v) x
        )


lazy : (() -> T a b) -> T a b
lazy thunk =
    succeed () |> andThen thunk


tail : T a b -> T a (List b)
tail (T f) =
    T (\(Branch _ xs) -> List.map f xs)


runT : T a b -> Rose a -> b
runT (T f) tree =
    f tree
