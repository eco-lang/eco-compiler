module TypeMismatchMaybeConsedOntoAListOfStringsTest exposing (..)

{-| Consing a `Maybe` onto a list of strings with `::` is rejected with a TYPE MISMATCH.

In `Just 1 :: [ "a" ]` the tail is a `List String`, so the head must be a
`String`, but it is a `Maybe` of a number.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Maybe consed onto a list of strings
-- CHECK: -- TYPE MISMATCH -

x = Just 1 :: [ "a" ]
