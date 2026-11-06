module TypeMismatchListConsedOntoAListOfStringsTest exposing (..)

{-| Consing a list onto a list of strings with `::` is rejected with a TYPE MISMATCH.

In `[ 1 ] :: [ "a" ]` the tail is a `List String`, so the head must be a `String`,
but it is a list of numbers.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list consed onto a list of strings
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] :: [ "a" ]
