module ErrorMessagesIssue203ListWithoutArgumentTest exposing (..)

{-| TOO FEW ARGS: `List` used in a type annotation without its argument.

<https://github.com/elm/error-message-catalog/issues/203>

With `foo : List -> List` and a body using `++`, Elm 0.18 crashed while printing the report
("type applications should start with a type atom"). The report must say `List` needs an
argument.

-}

-- COMPILE-ERROR: TOO FEW ARGS, List without its argument
-- CHECK: -- TOO FEW ARGS -
-- CHECK: The `List` type needs 1 argument, but I see 0 instead
-- CHECK-NOT: type atom


foo : List -> List
foo list =
    List.take 0 list ++ List.take 0 list
