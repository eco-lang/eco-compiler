module TooFewArgsAConstructorPatternWithTooFewArgumentsTest exposing (..)

{-| TOO FEW ARGS: a constructor pattern with too few arguments.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TOO FEW ARGS, a constructor pattern with too few arguments
-- CHECK: -- TOO FEW ARGS -

type Pair
    = Pair Int Int


first (Pair a) =
    a


testValue =
    first (Pair 1 2)
