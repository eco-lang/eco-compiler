module ErrorMessagesIssue234DivTooManyArgsTest exposing (main)

{-| `Html.div` applied to four arguments is reported as TOO MANY ARGS, saying it expects 2.

<https://github.com/elm/error-message-catalog/issues/234>

`main` is `Html.div [] [] [] []`. The report must say `div` expects 2 arguments and got 4,
and no report may say it expects 3.

-}

-- COMPILE-ERROR: TOO MANY ARGS, Html.div given four arguments
-- CHECK: -- TOO MANY ARGS -
-- CHECK: The `div` function expects 2 arguments, but it got 4 instead.
-- CHECK-NOT: expects 3 arguments

import Html


main =
    Html.div [] [] [] []
