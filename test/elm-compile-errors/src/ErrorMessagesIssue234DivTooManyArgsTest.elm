module ErrorMessagesIssue234DivTooManyArgsTest exposing (main)

{-| TOO MANY ARGS: `Html.div` given four arguments is reported once.

<https://github.com/elm/error-message-catalog/issues/234>

Elm 0.18 gave two reports for `Html.div [] [] [] []`, one saying `div` expects 3 arguments and
one saying it expects 2. There must be one report, saying it expects 2.

-}

-- COMPILE-ERROR: TOO MANY ARGS, Html.div given four arguments
-- CHECK: -- TOO MANY ARGS -
-- CHECK: The `div` function expects 2 arguments, but it got 4 instead.
-- CHECK-NOT: expects 3 arguments

import Html


main =
    Html.div [] [] [] []
