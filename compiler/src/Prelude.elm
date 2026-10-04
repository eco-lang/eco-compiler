module Prelude exposing (head, init, last)

{-| Gives code that knows a list is non-empty a way to take it apart without
handling a `Maybe` case that cannot occur.

`head`, `init` and `last` are partial functions named after those in Haskell's
`Prelude`: each is defined only on a non-empty list. On an empty list each
aborts through `Utils.Crash.crash`, with a message of the form
`*** Exception: Prelude.<name>: empty list`, instead of returning. Nothing
here checks the non-emptiness in advance; it is the caller's promise, and a
broken promise is a crash, not an error the caller can handle.

@docs head, init, last

-}

import List.Extra as List
import Utils.Crash exposing (crash)


{-| Returns the first element of `items`, aborting if `items` is empty.
-}
head : List a -> a
head items =
    case List.head items of
        Just item ->
            item

        Nothing ->
            crash "*** Exception: Prelude.head: empty list"


{-| Returns every element of `items` except the last, in order, aborting if
`items` is empty. A list of one element gives the empty list.
-}
init : List a -> List a
init items =
    case List.init items of
        Just initItems ->
            initItems

        Nothing ->
            crash "*** Exception: Prelude.init: empty list"


{-| Returns the last element of `items`, aborting if `items` is empty.
-}
last : List a -> a
last items =
    case List.last items of
        Just item ->
            item

        Nothing ->
            crash "*** Exception: Prelude.last: empty list"
