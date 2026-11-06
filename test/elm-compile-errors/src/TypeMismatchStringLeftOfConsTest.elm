module TypeMismatchStringLeftOfConsTest exposing (..)

{-| Consing a `String` onto a list of numbers with `::` is rejected with a TYPE MISMATCH.

In `"a" :: [ 1 ]` the element on the left must have the type of the list's elements.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of ::
-- CHECK: -- TYPE MISMATCH -

x = "a" :: [ 1 ]
