module CompilerIssue2241FoldMapInfiniteTypeHangTest exposing (main)

{-| The compiler rejects, with a type error, a call whose tuple-accumulating lambda does not fit the function it is passed to.

<https://github.com/elm/compiler/issues/2241>

In `break`, `foldMap` requires its third argument to have type `Float -> ( Float, Float ) -> ( Float, Float )`,
but the lambda given takes a tuple first and returns a tuple mixing its components with its second argument,
which leads the type checker to an infinite type. Elm 0.19.1 does not report this: it hangs
with memory growing without bound, or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


foldMap : (a -> b) -> (a -> c) -> (b -> c -> c) -> a -> c
foldMap fab fac fbc a = fac a

break : Float -> (Float, Float)
break input = foldMap identity (\x -> (x, x)) (\( low, high ) x -> ( min low x, max high x )) input


main =
    Html.text ""
