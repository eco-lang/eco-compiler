module TooFewArgsAConstructorPatternWithTooFewArgumentsTest exposing (..)

{-| A constructor pattern with fewer arguments than the constructor takes is rejected with a TOO FEW ARGS error.

`Pair` takes two `Int`s, but the argument pattern of `first` is `(Pair a)`.

-}

-- COMPILE-ERROR: TOO FEW ARGS, a constructor pattern with too few arguments
-- CHECK: -- TOO FEW ARGS -

type Pair
    = Pair Int Int


first (Pair a) =
    a


testValue =
    first (Pair 1 2)
