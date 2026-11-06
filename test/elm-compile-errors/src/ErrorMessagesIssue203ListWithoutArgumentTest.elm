module ErrorMessagesIssue203ListWithoutArgumentTest exposing (..)

{-| `List` used without its type argument in an annotation is reported as TOO FEW ARGS.

<https://github.com/elm/error-message-catalog/issues/203>

The annotation is `foo : List -> List`, and the body appends two lists with `++`. The report
must say that `List` needs 1 argument and got 0, and must not mention a "type atom".

-}

-- COMPILE-ERROR: TOO FEW ARGS, List without its argument
-- CHECK: -- TOO FEW ARGS -
-- CHECK: The `List` type needs 1 argument, but I see 0 instead
-- CHECK-NOT: type atom


foo : List -> List
foo list =
    List.take 0 list ++ List.take 0 list
