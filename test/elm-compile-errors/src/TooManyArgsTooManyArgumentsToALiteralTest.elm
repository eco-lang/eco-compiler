module TooManyArgsTooManyArgumentsToALiteralTest exposing (..)

{-| An integer literal applied to an argument is rejected with a TOO MANY ARGS error.

`x = 1 2` applies the literal `1`, which is not a function, to `2`.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to a literal
-- CHECK: -- TOO MANY ARGS -

x = 1 2
