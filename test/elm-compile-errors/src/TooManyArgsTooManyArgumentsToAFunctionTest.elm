module TooManyArgsTooManyArgumentsToAFunctionTest exposing (..)

{-| Applying a function to more arguments than it takes, `not True False`, is rejected with a TOO MANY ARGS error.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a function
-- CHECK: -- TOO MANY ARGS -

x = not True False
