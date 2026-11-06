module CompilerIssue2241FoldMapInfiniteTypeHangTest exposing (main)

{-| An infinite type through a fold-like function and a tuple accumulator.

<https://github.com/elm/compiler/issues/2241>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

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
