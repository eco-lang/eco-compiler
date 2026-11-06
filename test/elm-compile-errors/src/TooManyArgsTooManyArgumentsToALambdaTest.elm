module TooManyArgsTooManyArgumentsToALambdaTest exposing (..)

{-| Applying a one-argument lambda to two arguments, `(\a -> a + 1) 1 2`, is rejected with a TOO MANY ARGS error.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a lambda
-- CHECK: -- TOO MANY ARGS -

x = (\a -> a + 1) 1 2
