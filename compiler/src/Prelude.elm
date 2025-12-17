module Prelude exposing (head, init, last)

{-| Unsafe list operations that crash on empty lists, providing Haskell Prelude-style behavior.

This module provides partial functions that mirror Haskell's Prelude for list operations.
These functions are intentionally unsafe and will crash with descriptive error messages
when given empty lists, making them suitable for cases where the list is guaranteed to be non-empty.


# List Operations

@docs head, init, last

-}

import List.Extra as List
import Utils.Crash exposing (crash)


{-| Returns the first element of a list, crashing if the list is empty.
-}
head : List a -> a
head items =
    case List.head items of
        Just item ->
            item

        Nothing ->
            crash "*** Exception: Prelude.head: empty list"


{-| Returns all elements except the last one, crashing if the list is empty.
-}
init : List a -> List a
init items =
    case List.init items of
        Just initItems ->
            initItems

        Nothing ->
            crash "*** Exception: Prelude.init: empty list"


{-| Returns the last element of a list, crashing if the list is empty.
-}
last : List a -> a
last items =
    case List.last items of
        Just item ->
            item

        Nothing ->
            crash "*** Exception: Prelude.last: empty list"
