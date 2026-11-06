module TooManyArgsTooManyArgumentsToAnOperatorTest exposing (..)

{-| An operator function given three arguments is rejected with a TOO MANY ARGS error.

`(+)` takes two arguments; `x = (+) 1 2 3` passes a third.

-}

-- COMPILE-ERROR: TOO MANY ARGS, too many arguments to an operator
-- CHECK: -- TOO MANY ARGS -

x = (+) 1 2 3
