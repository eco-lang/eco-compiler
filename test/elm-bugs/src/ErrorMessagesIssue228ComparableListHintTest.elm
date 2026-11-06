module ErrorMessagesIssue228ComparableListHintTest exposing (main)

{-| A Set of lists of a custom type is rejected (the custom type is not comparable), but the
hint blames the List.

<https://github.com/elm/error-message-catalog/issues/228>

Elm 0.19.1 rejects `Set.fromList [ [ Apple ] ]` with a TYPE MISMATCH whose hint says "I do not
know how to compare `List` values. I can only compare ... lists of comparable values". Lists
are comparable; it is `Fruit` that is not, so the hint is false.

-}

-- COMPILE-ERROR: Set of lists of a custom type
-- CHECK: -- TYPE MISMATCH -
-- CHECK-NOT: I do not know how to compare `List` values

import Html exposing (text)
import Set


type Fruit
    = Apple
    | Banana


s =
    Set.fromList [ [ Apple ], [ Banana ] ]


main =
    text (String.fromInt (Set.size s))
