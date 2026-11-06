module TooManyArgsTooManyArgumentsToALocalTest exposing (..)

{-| A top-level `Int` value applied to an argument is rejected with a TOO MANY ARGS error.

`y` is `5`, which is not a function, and `x` applies it to `1`.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a local
-- CHECK: -- TOO MANY ARGS -

y = 5

x = y 1
